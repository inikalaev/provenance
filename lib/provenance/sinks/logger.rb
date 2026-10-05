# frozen_string_literal: true

module Provenance
  module Sinks
    # Writes one JSON line per event to a logger (Rails.logger by default).
    class Logger
      # @param logger [::Logger, nil] defaults to the configured Provenance logger
      # @param level [Symbol] log level
      def initialize(logger: nil, level: :info)
        @logger = logger
        @level = level
      end

      # @param batch [Array<Hash>]
      # @return [void]
      def deliver(batch)
        logger = @logger || Provenance.config.logger
        batch.each { |event| logger.public_send(@level, JSON.generate(event)) }
      end
    end
  end
end
