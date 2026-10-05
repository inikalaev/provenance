# frozen_string_literal: true

module Provenance
  # Builds the immutable native event (schema "provenance/event@2") for an action.
  module Event
    # Value of the +schema+ field.
    SCHEMA = "provenance/event@2"

    module_function

    # @param action [Action]
    # @return [Hash{String => Object}] deeply frozen, JSON-safe event
    def build(action)
      event = {
        "schema" => SCHEMA,
        "id" => action.id,
        "occurred_at" => action.started_at.utc.iso8601(3),
        "app" => Provenance.config.app_name,
        "action" => {"kind" => action.kind, "name" => action.name.to_s, "caused_by" => action.caused_by},
        "actor" => action.actor&.to_h,
        "request" => (action.kind == "http") ? JsonSafe.call(action.request) : nil,
        "outcome" => {"result" => action.result, "error" => action.error},
        "changes" => action.changes.map(&:to_h),
        "metadata" => JsonSafe.call(Redactor.deep(action.metadata))
      }
      deep_freeze(event)
    end

    # Returns a frozen deep copy of a JSON-like structure.
    #
    # @param value [Object]
    # @return [Object]
    def deep_freeze(value)
      case value
      when Hash then value.to_h { |k, v| [k.to_s.freeze, deep_freeze(v)] }.freeze
      when Array then value.map { |v| deep_freeze(v) }.freeze
      when String then value.frozen? ? value : value.dup.freeze
      else value
      end
    end
  end
end
