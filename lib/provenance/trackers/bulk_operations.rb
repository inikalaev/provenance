# frozen_string_literal: true

require "active_record"

module Provenance
  module Trackers
    # Intercepts bulk operations (`update_all`/`delete_all`) which bypass
    # ActiveRecord callbacks and therefore never reach the regular Trackable
    # path. Captures the ids of the affected rows before execution and records
    # the change in the journal.
    module BulkOperations
      def update_all(*args)
        Provenance::Trackers::BulkOperations.track(self, :bulk_update, args.first) { super }
      end

      def delete_all(*args)
        Provenance::Trackers::BulkOperations.track(self, :bulk_delete, nil) { super }
      end

      class << self
        def track(relation, action, updates)
          journal = Provenance::Context.journal
          klass = relation.klass

          return yield unless trackable?(journal, klass)

          ids, truncated = safe_collect_ids(relation, klass)
          transaction_id = safe_transaction_id(klass)

          result = yield

          begin
            journal.add_bulk_change(klass, action, ids, updates,
              truncated: truncated, transaction_id: transaction_id)
          rescue StandardError
            # Auditing must never break the underlying operation.
          end

          result
        end

        private

        def trackable?(journal, klass)
          journal &&
            Provenance.config.track_bulk_operations &&
            klass.respond_to?(:include?) &&
            klass.include?(Provenance::Trackable)
        end

        def safe_collect_ids(relation, klass)
          pk = klass.primary_key
          return [[], false] unless pk

          max = Provenance.config.bulk_operations_max_ids.to_i
          ids = relation.unscope(:select).limit(max + 1).pluck(pk)
          [ids.first(max), ids.size > max]
        rescue StandardError
          [[], false]
        end

        def safe_transaction_id(klass)
          Provenance::TransactionKey.for_connection(klass.connection)
        rescue StandardError
          Provenance::Context.request_id
        end
      end
    end
  end
end

ActiveRecord::Relation.prepend(Provenance::Trackers::BulkOperations) if defined?(ActiveRecord::Relation)
