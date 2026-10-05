# frozen_string_literal: true

module Provenance
  module Serializers
    # CloudEvents 1.0 structured-mode JSON with the native event as +data+.
    module CloudEvents
      module_function

      # @param event [Hash] native event
      # @return [Array<Hash>]
      def call(event)
        [{
          "specversion" => "1.0",
          "id" => event["id"],
          "source" => event["app"],
          "type" => "provenance.action.#{event.dig("action", "kind")}",
          "subject" => event.dig("action", "name"),
          "time" => event["occurred_at"],
          "datacontenttype" => "application/json",
          "dataschema" => "urn:provenance:event:2",
          "data" => event
        }]
      end
    end
  end
end
