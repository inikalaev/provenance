# frozen_string_literal: true

module Provenance
  module Sinks
    # Writes one JSON line per event to any IO.
    class IO
      # @param io [#write]
      def initialize(io = $stdout)
        @io = io
        @lock = Mutex.new
      end

      # @param batch [Array<Hash>]
      # @return [void]
      def deliver(batch)
        lines = batch.map { |event| "#{JSON.generate(event)}\n" }.join
        @lock.synchronize do
          @io.write(lines)
          @io.flush if @io.respond_to?(:flush)
        end
      end
    end
  end
end
