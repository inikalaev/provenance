# frozen_string_literal: true

# Minimal stand-in for the rdkafka gem used by the Kafka sink spec.
module Rdkafka
  class FakeProducer
    Handle = Struct.new(:producer) do
      def wait(max_wait_timeout:)
        producer.waited += 1
      end
    end

    attr_reader :messages
    attr_accessor :waited, :closed

    def initialize
      @messages = []
      @waited = 0
    end

    def produce(**message)
      @messages << message
      Handle.new(self)
    end

    def close
      @closed = true
    end
  end

  class Config
    def initialize(config)
      @config = config
    end

    def producer
      FakeProducer.new
    end
  end
end
