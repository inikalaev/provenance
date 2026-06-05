# frozen_string_literal: true

module Provenance
  # Builds the transaction key used to group changes inside the journal.
  # A single format is shared across the gem (Trackable and BulkOperations);
  # otherwise rollback cleanup (`remove_changes_for_transaction`) would fail to
  # match the paired records.
  module TransactionKey
    module_function

    def for_connection(connection)
      request_id = Provenance::Context.request_id
      return request_id unless connection.transaction_open?

      current = connection.current_transaction
      current ? "#{request_id}:#{current.object_id}" : "#{request_id}:#{connection.open_transactions}"
    end
  end
end
