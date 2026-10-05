# frozen_string_literal: true

module Provenance
  # Controller integration, included into ActionController::Base and ::API.
  #
  # @example
  #   class InvoicesController < ApplicationController
  #     provenance_action_name ->(controller) { "billing.#{controller.action_name}" }
  #     skip_provenance only: :preview
  #   end
  module Controller
    extend ActiveSupport::Concern

    included do
      class_attribute :_provenance_action_name, instance_accessor: false, default: nil
      class_attribute :_provenance_skip, instance_accessor: false, default: nil
    end

    class_methods do
      # Overrides the action name for this controller.
      #
      # @param callable [#call] receives the controller, returns the name
      # @return [void]
      def provenance_action_name(callable = nil, &block)
        self._provenance_action_name = callable || block
      end

      # Excludes actions of this controller from auditing.
      #
      # @param only [Array<Symbol>, Symbol, nil]
      # @param except [Array<Symbol>, Symbol, nil]
      # @return [void]
      def skip_provenance(only: nil, except: nil)
        self._provenance_skip = {only: only && Array(only).map(&:to_s), except: Array(except).map(&:to_s)}
      end
    end

    # @api private
    def process_action(*)
      Provenance.current&.context&.controller ||= self
      super
    end

    # Name of the current action for Provenance.
    #
    # @return [String]
    def provenance_action_name
      custom = self.class._provenance_action_name
      custom ? custom.call(self).to_s : "#{controller_path}##{action_name}"
    end

    # @return [Boolean] whether this controller action is excluded
    def skip_provenance?
      rule = self.class._provenance_skip
      return false unless rule
      return false if rule[:except].include?(action_name.to_s)

      rule[:only].nil? || rule[:only].include?(action_name.to_s)
    end

    private

    def append_info_to_payload(payload)
      super
      payload[:provenance_action_name] = provenance_action_name
      payload[:provenance_skip] = skip_provenance?
    rescue => e
      Provenance.config.report_error(e)
    end

    # Applies the process_action.action_controller payload to the current action.
    #
    # @api private
    module Subscriber
      module_function

      # @param payload [Hash]
      # @return [void]
      def call(payload)
        action = Provenance.current
        return unless action&.kind == "http"

        if payload[:provenance_skip]
          action.skip!
          return
        end
        action.name = payload[:provenance_action_name] || "#{payload[:controller]}##{payload[:action]}"
        action.request["status"] = payload[:status] if payload[:status]
        action.fail!(payload[:exception_object]) if payload[:exception_object]
      end
    end
  end
end
