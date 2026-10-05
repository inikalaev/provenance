# frozen_string_literal: true

begin
  require "rdkafka"
rescue LoadError
  raise LoadError, "the :kafka sink needs the rdkafka gem; add it to your Gemfile"
end

module Provenance
  module Sinks
    # Produces one Kafka message per event, keyed by event id. Optional: requires
    # the +rdkafka+ gem.
    #
    # @example
    #   require "provenance/sinks/kafka"
    #   c.sink :kafka, topic: "audit", config: {"bootstrap.servers": "kafka:9092"}
    class Kafka
      # @param topic [String]
      # @param config [Hash] rdkafka producer configuration
      # @param producer [Object, nil] an existing rdkafka producer
      # @param timeout [Numeric] seconds to wait for delivery reports
      def initialize(topic:, config: {}, producer: nil, timeout: 10)
        @topic = topic
        @producer = producer || Rdkafka::Config.new(config).producer
        @timeout = timeout
      end

      # @param batch [Array<Hash>]
      # @return [void]
      def deliver(batch)
        handles = batch.map do |event|
          @producer.produce(topic: @topic, payload: JSON.generate(event), key: (event["id"] || event.dig("metadata", "uid")).to_s)
        end
        handles.each { |handle| handle.wait(max_wait_timeout: @timeout) }
      end

      # Closes the underlying producer.
      #
      # @return [void]
      def close
        @producer.close
      end
    end
  end
end
