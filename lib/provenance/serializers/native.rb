# frozen_string_literal: true

module Provenance
  module Serializers
    # The native "provenance/event@2" format, as built by {Event.build}.
    module Native
      module_function

      # @param event [Hash] native event
      # @return [Array<Hash>]
      def call(event)
        [event]
      end
    end
  end
end
