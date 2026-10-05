# frozen_string_literal: true

require "provenance/sinks/logger"
require "provenance/sinks/io"
require "provenance/sinks/http"
require "provenance/sinks/proc"
require "provenance/sinks/memory"

module Provenance
  # Destinations for serialized events. A sink is any object responding to
  # +#deliver(batch)+, where +batch+ is an Array of serialized events (Hashes).
  module Sinks
    module_function

    # Builds a sink from a type symbol or returns a sink object unchanged.
    #
    # @param type [Symbol, #deliver]
    # @return [#deliver]
    def build(type, *args, **options, &block)
      return type if type.respond_to?(:deliver)

      case type.to_sym
      when :logger then Logger.new(*args, **options)
      when :io then IO.new(*args, **options)
      when :http then HTTP.new(*args, **options)
      when :proc then Proc.new(*args, &block)
      when :memory then Memory.new
      when :kafka
        require "provenance/sinks/kafka"
        Kafka.new(*args, **options)
      else raise ConfigurationError, "unknown sink #{type.inspect}"
      end
    end
  end
end
