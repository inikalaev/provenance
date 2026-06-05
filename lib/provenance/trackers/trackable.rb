# frozen_string_literal: true

require "active_support/concern"
require "active_record"

module Provenance
  # Model-side concern. Captures create/update/destroy through ActiveRecord
  # callbacks, groups changes by transaction key, discards them on rollback and
  # flushes the audit log once every transaction has committed. Also tracks
  # `has_and_belongs_to_many` join-table changes, which bypass model callbacks,
  # via SQL notifications.
  module Trackable
    extend ActiveSupport::Concern

    INSERT_DELETE_REGEX = /\b(INSERT|DELETE)\s+(INTO|FROM)\b/i
    INSERT_INTO_REGEX = /\bINSERT\s+INTO\b/i
    TABLE_NAME_REGEX = /(?:INSERT\s+INTO|DELETE\s+FROM)\s+["`]?(\w+)["`]?/i
    INSERT_COLUMNS_REGEX = /INSERT\s+INTO\s+["`]?\w+["`]?\s*\(([^)]+)\)/i
    WHERE_REGEX = /WHERE\s+(.+?)(?:\s+RETURNING|\s*$)/i

    def self.included(base)
      super

      base.class_eval do
        before_create :capture_transaction_id
        before_update :capture_transaction_id
        before_destroy :capture_transaction_id

        after_update :capture_update
        after_create :capture_create
        after_destroy :capture_destroy

        after_commit :try_send_audit_after_commit
        after_rollback :clear_tracked_changes

        class << self
          alias_method :original_has_and_belongs_to_many, :has_and_belongs_to_many

          def has_and_belongs_to_many(name, scope = nil, **options, &extension)
            original_has_and_belongs_to_many(name, scope, **options, &extension).tap do
              association = reflect_on_association(name)
              next unless association

              Provenance::Trackable.register_habtm_join_table_from_association(association, self.name, name)
            end
          end
        end

        base.setup_habtm_tracking
      end

      # has_and_belongs_to_many join-table writes bypass model callbacks, so we
      # observe them through SQL notifications and fold them into the journal.
      # The change is recorded synchronously on the request thread; delivery is
      # handled by Auditable once every transaction has committed, so no extra
      # post-commit scheduling is required here.
      return if @habtm_sql_subscribed

      ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
        Provenance::Trackable.track_habtm_sql_changes(payload)
      end
      @habtm_sql_subscribed = true
    end

    class_methods do
      def sensitive_attributes(*attributes)
        @sensitive_attributes = Array(attributes).flatten
      end

      def sensitive_attributes_list
        @sensitive_attributes || []
      end

      def setup_habtm_tracking
        reflect_on_all_associations(:has_and_belongs_to_many).each do |association|
          Provenance::Trackable.register_habtm_join_table_from_association(association, name, association.name)
        end
      end
    end

    # Registry of join tables we watch, keyed by table name. Populated when a
    # model that includes Trackable declares a has_and_belongs_to_many.
    def self.register_habtm_join_table_from_association(association, model_class_name, association_name)
      join_table = association.join_table
      (@habtm_join_tables ||= {})[join_table] ||= []
      @habtm_join_tables[join_table] << {
        model_class_name: model_class_name,
        association_name: association_name,
        foreign_key: association.foreign_key,
        association_foreign_key: association.association_foreign_key
      }
    end

    def self.habtm_join_tables
      @habtm_join_tables ||= {}
    end

    # Inspects a SQL statement; if it touches a watched join table, reconstructs
    # the affected ids and folds the change into the journal as an update.
    def self.track_habtm_sql_changes(payload)
      journal = Provenance::Context.journal
      return unless journal

      sql = payload[:sql].to_s
      return unless sql.match?(INSERT_DELETE_REGEX)

      table_name = sql.match(TABLE_NAME_REGEX)&.[](1)
      return unless table_name && (info_list = habtm_join_tables[table_name])

      action = sql.match?(INSERT_INTO_REGEX) ? :add : :remove

      info_list.each do |info|
        values_list = extract_habtm_values(sql, payload[:binds], action, info[:foreign_key], info[:association_foreign_key])
        next unless values_list

        model = info[:model_class_name].constantize.find_by(id: values_list[0])
        next unless model&.persisted?

        associated_ids = Array(values_list[1])
        model.send(:track_habtm_changes, info[:association_name], action, associated_ids)
      end
    end

    def self.extract_habtm_values(sql, binds, action, foreign_key, association_foreign_key)
      return nil unless binds

      if action == :add
        extract_insert_values(sql, binds, foreign_key, association_foreign_key)
      else
        extract_delete_values(sql, binds, foreign_key, association_foreign_key)
      end
    end

    def self.extract_insert_values(sql, binds, foreign_key, association_foreign_key)
      columns = sql.match(INSERT_COLUMNS_REGEX)&.[](1)
      return nil unless columns

      columns = columns.split(",").map { |c| c.strip.delete('"`') }
      fk_idx = columns.index(foreign_key)
      afk_idx = columns.index(association_foreign_key)
      return nil unless fk_idx && afk_idx && binds[fk_idx] && binds[afk_idx]

      [extract_value(binds[fk_idx]), extract_value(binds[afk_idx])]
    end

    def self.extract_delete_values(sql, binds, foreign_key, association_foreign_key)
      conditions = sql.match(WHERE_REGEX)&.[](1)
      return nil unless conditions

      fk_pattern = /(?:["`]\w+["`]\.)?["`]?#{Regexp.escape(foreign_key)}["`]?\s*[=<>]\s*\$(\d+)/i
      fk_match = conditions.match(fk_pattern)
      return nil unless fk_match

      fk_idx = fk_match[1].to_i - 1
      return nil unless binds[fk_idx]

      afk_pattern = /(?:["`]\w+["`]\.)?["`]?#{Regexp.escape(association_foreign_key)}["`]?\s*[=<>]\s*\$(\d+)/i
      afk_match = conditions.match(afk_pattern)

      if afk_match
        afk_idx = afk_match[1].to_i - 1
        return nil unless binds[afk_idx]

        [extract_value(binds[fk_idx]), extract_value(binds[afk_idx])]
      else
        in_params = conditions.match(/#{Regexp.escape(association_foreign_key)}["`]?\s+IN\s*\(([^)]+)\)/i)&.[](1)
        return nil unless in_params

        param_indices = in_params.scan(/\$(\d+)/).flatten.map(&:to_i).map { |i| i - 1 }
        associated_ids = param_indices.filter_map { |idx| extract_value(binds[idx]) if binds[idx] }
        return nil if associated_ids.empty?

        [extract_value(binds[fk_idx]), associated_ids]
      end
    end

    def self.extract_value(bind)
      return bind.value if bind.respond_to?(:value)
      return bind.value_for_database if bind.respond_to?(:value_for_database)

      bind
    end

    private

    def capture_transaction_id
      @_audit_transaction_id = current_transaction_id
      journal = Provenance::Context.journal
      return unless journal && self.class.connection.transaction_open?

      journal.register_transaction(@_audit_transaction_id)
    end

    def capture_create
      journal = Provenance::Context.journal
      return unless journal

      attributes_data = if saved_changes.any?
                          saved_changes.transform_values(&:last)
                        else
                          attributes.except("id", "created_at", "updated_at")
                        end

      journal.add_change(
        self,
        :create,
        {
          attributes: attributes_data,
          transaction_id: captured_transaction_id
        }
      )
    end

    def capture_update
      journal = Provenance::Context.journal
      return unless journal

      changed_attributes = saved_changes.transform_values(&:last)
      previous_changes = saved_changes.transform_values(&:first)

      journal.add_change(
        self,
        :update,
        {
          changed_attributes: changed_attributes,
          previous_changes: previous_changes,
          transaction_id: captured_transaction_id
        }
      )
    end

    def capture_destroy
      journal = Provenance::Context.journal
      return unless journal

      journal.add_change(
        self,
        :destroy,
        {
          attributes: attributes.except("id", "created_at", "updated_at"),
          transaction_id: captured_transaction_id
        }
      )
    end

    def try_send_audit_after_commit
      return unless Provenance::Context.pending_audit_log

      journal = Provenance::Context.journal
      return unless journal

      journal.complete_transaction(@_audit_transaction_id) if @_audit_transaction_id

      active_transactions = journal.instance_variable_get(:@active_transactions)
      return if active_transactions.any? || Thread.current[:provenance_send_scheduled]

      Thread.current[:provenance_send_scheduled] = true
      begin
        Provenance::Context.pending_audit_log.call
      ensure
        Thread.current[:provenance_send_scheduled] = nil
      end
    end

    def clear_tracked_changes
      journal = Provenance::Context.journal
      return unless journal && @_audit_transaction_id

      journal.remove_changes_for_transaction(@_audit_transaction_id)
    end

    def captured_transaction_id
      @_audit_transaction_id || Provenance::Context.request_id || "no-request-id"
    end

    def current_transaction_id
      Provenance::TransactionKey.for_connection(self.class.connection)
    end

    def track_habtm_changes(association_name, action, associated_ids)
      journal = Provenance::Context.journal
      return unless journal && persisted?

      association = self.class.reflect_on_association(association_name)
      return unless association&.macro == :has_and_belongs_to_many

      connection = self.class.connection
      register_transaction_if_needed(journal, connection)

      ids_key = "#{association_name}_ids"
      transaction_id = captured_transaction_id
      request_id_value = Provenance::Context.request_id.to_s

      existing_change = find_existing_habtm_change(journal, ids_key, transaction_id, request_id_value)
      current_ids = get_current_habtm_ids(connection, association)
      associated_ids_str = associated_ids.map(&:to_s)

      if existing_change
        existing_change[:changes][:changed_attributes][ids_key] = current_ids
        if action == :remove
          existing_previous = existing_change[:changes][:previous_changes][ids_key] || []
          existing_change[:changes][:previous_changes][ids_key] = (existing_previous + associated_ids_str).uniq
        end
      else
        previous_ids = action == :add ? current_ids - associated_ids_str : current_ids + associated_ids_str
        journal.add_change(self, :update, {
          changed_attributes: { ids_key => current_ids },
          previous_changes: { ids_key => previous_ids },
          transaction_id: transaction_id
        })
      end

      journal.complete_transaction(transaction_id)
    end

    def register_transaction_if_needed(journal, connection)
      return unless connection.transaction_open?

      @_audit_transaction_id ||= current_transaction_id
      journal.register_transaction(@_audit_transaction_id)
    end

    def find_existing_habtm_change(journal, ids_key, transaction_id, request_id_value)
      model_name = self.class.name
      journal.changes.find do |change|
        change[:model] == model_name &&
          change[:model_id] == id &&
          change[:action] == "update" &&
          change[:changes][:changed_attributes]&.key?(ids_key) &&
          (change[:transaction_id]&.start_with?(request_id_value) || change[:transaction_id] == transaction_id)
      end
    end

    def get_current_habtm_ids(connection, association)
      sql = "SELECT #{connection.quote_column_name(association.association_foreign_key)} " \
            "FROM #{connection.quote_table_name(association.join_table)} " \
            "WHERE #{connection.quote_column_name(association.foreign_key)} = #{connection.quote(id)}"
      connection.select_values(sql).map(&:to_s)
    end
  end
end
