# frozen_string_literal: true

require "provenance/serializers/native"
require "provenance/serializers/ocsf"
require "provenance/serializers/cloud_events"

module Provenance
  # Converts native events into the configured wire format.
  module Serializers
    module_function

    # @param format [Symbol] :native, :ocsf or :cloudevents
    # @return [#call] serializer returning an Array of serialized events per native event
    def for(format)
      case format.to_sym
      when :native then Native
      when :ocsf then OCSF
      when :cloudevents then CloudEvents
      else raise ConfigurationError, "unknown format #{format.inspect}"
      end
    end

    # @param events [Array<Hash>] native events
    # @param format [Symbol]
    # @return [Array<Hash>] serialized events; OCSF may produce several per native event
    def serialize_all(events, format)
      serializer = self.for(format)
      events.flat_map { |event| serializer.call(event) }
    end
  end
end
