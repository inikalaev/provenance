# frozen_string_literal: true

module Provenance
  module Sinks
    # Calls a block or callable with each batch.
    class Proc
      # @param callable [#call, nil]
      def initialize(callable = nil, &block)
        @callable = callable || block
        raise ArgumentError, "proc sink needs a callable or a block" unless @callable.respond_to?(:call)
      end

      # @param batch [Array<Hash>]
      # @return [void]
      def deliver(batch)
        @callable.call(batch)
      end
    end
  end
end
