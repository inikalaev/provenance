# frozen_string_literal: true

module Provenance
  module Outbox
    # A stored event awaiting or past delivery.
    class Record < ActiveRecord::Base
      # Row awaiting delivery.
      PENDING = "pending"
      # Row delivered to every sink.
      DELIVERED = "delivered"

      self.table_name = "provenance_outbox"

      scope :pending, -> { where(status: PENDING) }
      scope :delivered, -> { where(status: DELIVERED) }

      # @return [Hash] the stored native event
      def event
        JSON.parse(payload)
      end
    end
  end
end
