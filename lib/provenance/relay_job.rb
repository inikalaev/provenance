# frozen_string_literal: true

module Provenance
  # Delivers pending outbox rows. Enqueued after every outbox write when
  # +outbox_enqueue_relay+ is on; can also be scheduled periodically.
  class RelayJob < ActiveJob::Base
    skip_provenance if respond_to?(:skip_provenance)

    # @param batch_size [Integer, nil]
    # @return [Integer] delivered rows
    def perform(batch_size: nil)
      Outbox::Relay.run(batch_size: batch_size || Provenance.config.outbox_batch_size)
    end
  end
end
