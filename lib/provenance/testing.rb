# frozen_string_literal: true

module Provenance
  # Test helpers. While {capture} runs, tracking is enabled regardless of
  # +config.enabled+ and events go to the capture instead of the outbox or sinks.
  module Testing
    @captures = []
    @lock = Mutex.new

    class << self
      # Collects the native events emitted while the block runs.
      #
      # @return [Array<Hash>] native events
      def capture
        events = []
        @lock.synchronize { @captures << events }
        begin
          yield
        ensure
          @lock.synchronize { @captures.delete_if { |c| c.equal?(events) } }
        end
        events
      end

      # @return [Boolean] whether a capture is active
      def capturing?
        !@captures.empty?
      end

      # @api private
      def record(event)
        @lock.synchronize { @captures.each { |c| c << event } }
      end
    end
  end
end
