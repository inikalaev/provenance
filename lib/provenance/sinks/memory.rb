# frozen_string_literal: true

module Provenance
  module Sinks
    # Keeps delivered events in memory. Intended for tests.
    class Memory
      def initialize
        @events = []
        @lock = Mutex.new
      end

      # @param batch [Array<Hash>]
      # @return [void]
      def deliver(batch)
        @lock.synchronize { @events.concat(batch) }
      end

      # @return [Array<Hash>] a copy of the delivered events
      def events
        @lock.synchronize { @events.dup }
      end

      # @return [void]
      def clear
        @lock.synchronize { @events.clear }
      end
    end
  end
end
