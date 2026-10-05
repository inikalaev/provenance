# frozen_string_literal: true

require "digest"

module Provenance
  # Builds entity changes from model callbacks and bulk relation calls and attaches
  # them to the current action once their transaction commits.
  module Recorder
    BULK_KEY = :provenance_bulk_depth
    private_constant :BULK_KEY

    module_function

    # Records a create, update or destroy of a single record.
    #
    # @param record [ActiveRecord::Base]
    # @param operation [Symbol] :create, :update or :destroy
    # @return [void]
    def record(record, operation)
      options = options_for(record.class)
      return unless options
      return if options.ignore_if&.call(record)

      raw = case operation
      when :create, :destroy then record.attributes.compact
      when :update then record.saved_changes
      end
      diff = filter(record.class, raw, options)
      return if operation == :update && diff.empty?

      change = EntityChange.new(entity: record.class.name, entity_id: record.id, operation: operation, diff: diff)
      append(record.class, change, "#{record.class.name}.#{operation}")
    end

    # Records a link or unlink through a tracked association.
    #
    # @param owner [ActiveRecord::Base]
    # @param association [Symbol]
    # @param target [ActiveRecord::Base]
    # @param operation [Symbol] :link or :unlink
    # @return [void]
    def association(owner, association, target, operation)
      options = options_for(owner.class)
      return unless options
      return if options.ignore_if&.call(owner)

      change = EntityChange.new(
        entity: owner.class.name, entity_id: -> { owner.id }, operation: operation, association: association,
        target: {"type" => target.class.name, "id" => -> { target.id }}
      )
      append(owner.class, change, "#{owner.class.name}.#{operation}")
    end

    # Wraps update_all/delete_all on a relation of a tracked model.
    #
    # @param relation [ActiveRecord::Relation]
    # @param operation [Symbol] :bulk_update or :bulk_delete
    # @param updates [Hash, String, Array, nil] the update_all argument
    # @yieldreturn [Integer] affected rows
    # @return [Integer] the block's return value
    def bulk(relation, operation, updates: nil)
      model = relation.model
      options = options_for(model)
      return yield if options.nil? || bulk_depth.positive?

      ids, truncated = bulk_ids(relation)
      count = nested_bulk { yield }
      diff = updates.is_a?(Hash) ? filter(model, updates.to_h { |k, v| [k.to_s, [nil, v]] }, options) : nil
      change = EntityChange.new(
        entity: model.name, operation: operation, diff: diff, count: count,
        where: fingerprint(relation), ids: ids, truncated: truncated
      )
      append(model, change, "#{model.name}.#{operation}")
      count
    end

    # Wraps insert_all/upsert_all on a tracked model.
    #
    # @param relation [ActiveRecord::Relation]
    # @param attributes [Array<Hash>, Hash]
    # @yieldreturn [ActiveRecord::Result]
    # @return [ActiveRecord::Result] the block's return value
    def bulk_insert(relation, attributes)
      model = relation.model
      options = options_for(model)
      return yield if options.nil? || bulk_depth.positive?

      result = nested_bulk { yield }
      rows = attributes.is_a?(Hash) ? [attributes] : Array(attributes)
      limit = Provenance.config.bulk_ids_limit
      ids = inserted_ids(model, rows, result)
      change = EntityChange.new(
        entity: model.name, operation: :bulk_insert, count: rows.size,
        ids: ids.first(limit), truncated: ids.size > limit
      )
      append(model, change, "#{model.name}.bulk_insert")
      result
    end

    # Attaches a change to the current action after the surrounding transaction
    # commits, or to an implicit +custom+ action when none is open.
    #
    # @param model [Class]
    # @param change [EntityChange]
    # @param implicit_name [String]
    # @return [void]
    def append(model, change, implicit_name)
      action = Provenance.current
      if action
        after_commit(model) { action.add_change(change) }
      else
        action = Action.new(kind: :custom, name: implicit_name)
        after_commit(model) { action.add_change(change) }
        Emitter.finish(action)
      end
    end

    # Runs the block when the model's innermost joinable transaction commits, or
    # immediately when none is open. Rolled-back transactions never run it.
    #
    # @param model [Class]
    # @return [void]
    def after_commit(model, &block)
      transaction = model.connection_pool.active_connection&.current_transaction
      if transaction&.open? && transaction.joinable?
        transaction.after_commit(&block)
      else
        block.call
      end
    end

    # @api private
    def options_for(model)
      return nil unless Provenance.enabled?

      Provenance.registry.options_for(model)
    end

    # @api private
    def filter(model, attributes, options)
      primary_keys = Array(model.primary_key).map(&:to_s)
      diff = attributes.to_h { |k, v| [k.to_s, v] }
        .select { |name, _| !primary_keys.include?(name) && options.track?(name) }
      Redactor.diff(diff, options.redact + encrypted_attributes(model))
    end

    # @api private
    def encrypted_attributes(model)
      model.respond_to?(:encrypted_attributes) ? Array(model.encrypted_attributes).map(&:to_s) : []
    end

    # @api private
    def bulk_ids(relation)
      limit = Provenance.config.bulk_ids_limit
      ids = if relation.loaded?
        relation.records.map(&:id)
      else
        fetch = limit + 1
        fetch = [relation.limit_value, fetch].min if relation.limit_value
        relation.limit(fetch).pluck(*Array(relation.model.primary_key))
      end
      [ids.first(limit).map(&:to_s), ids.size > limit]
    end

    # @api private
    def inserted_ids(model, rows, result)
      primary_key = model.primary_key
      return [] unless primary_key.is_a?(String)

      ids = if result.respond_to?(:columns) && result.columns.include?(primary_key)
        result.rows.map { |row| row[result.columns.index(primary_key)] }
      else
        rows.filter_map { |row| row[primary_key] || row[primary_key.to_sym] }
      end
      ids.map(&:to_s)
    end

    # Fingerprint of a relation's WHERE clause with bind values replaced by
    # placeholders, so the same query shape yields the same fingerprint.
    #
    # @param relation [ActiveRecord::Relation]
    # @return [String, nil] "sha256:<16 hex chars>"
    def fingerprint(relation)
      return nil if relation.where_clause.empty?

      sql = relation.model.with_connection do |connection|
        connection.visitor.compile(relation.where_clause.ast, Arel::Collectors::SQLString.new)
      end
      "sha256:#{Digest::SHA256.hexdigest(sql)[0, 16]}"
    end

    # @api private
    def bulk_depth
      ActiveSupport::IsolatedExecutionState[BULK_KEY].to_i
    end

    # @api private
    def nested_bulk
      state = ActiveSupport::IsolatedExecutionState
      state[BULK_KEY] = bulk_depth + 1
      yield
    ensure
      state[BULK_KEY] -= 1
    end
  end
end
