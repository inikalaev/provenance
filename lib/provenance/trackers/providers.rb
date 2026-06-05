# frozen_string_literal: true

require "active_support/concern"
require "active_support/inflector"

module Provenance
  module Trackers
    # Shared controller-side helpers: per-action opt-outs, custom event types,
    # value providers and the recursive sanitizers used when serializing audit
    # payloads.
    module Providers
      extend ActiveSupport::Concern

      class_methods do
        def skip_model_change_tracking(*actions)
          @skip_model_change_tracking_actions ||= []
          @skip_model_change_tracking_actions += actions.map(&:to_s)
        end

        def skip_model_change_tracking_actions
          @skip_model_change_tracking_actions || []
        end

        def custom_audit_event_type(action, event_type)
          @custom_audit_event_types ||= {}
          @custom_audit_event_types[action] = event_type
        end

        def skip_audit_logging(*actions)
          @skip_audit_logging_actions ||= []
          @skip_audit_logging_actions += actions.map(&:to_s)
        end

        def skip_audit_logging_actions
          @skip_audit_logging_actions || []
        end
      end

      private

      def username_from_provider
        return nil unless Provenance.config.username_provider

        call_provider(Provenance.config.username_provider)
      end

      def roles_from_provider
        return [] unless Provenance.config.roles_provider

        call_provider(Provenance.config.roles_provider)
      end

      def remote_ip_from_provider
        return nil unless Provenance.config.remote_ip_provider

        call_provider(Provenance.config.remote_ip_provider)
      end

      def session_id_from_provider
        return nil unless Provenance.config.session_id_provider

        call_provider(Provenance.config.session_id_provider)
      end

      def origin_ip_from_provider
        return nil unless Provenance.config.origin_ip_provider

        call_provider(Provenance.config.origin_ip_provider)
      end

      def call_provider(provider)
        if provider.respond_to?(:call) || provider.is_a?(Proc)
          provider.call(self)
        else
          provider
        end
      end

      def filter_sensitive_params(params)
        sensitive_attrs = Provenance.config.sensitive_attributes
        return params if sensitive_attrs.empty?

        case params
        when Hash
          filtered_data = {}
          params.each do |key, value|
            filtered_data[key] = if sensitive_attrs.include?(key.to_s)
                                   "[FILTERED]"
                                 else
                                   filter_sensitive_params(value)
                                 end
          end
          filtered_data
        when Array
          params.map { |item| filter_sensitive_params(item) }
        else
          params
        end
      end

      def generate_event_type
        controller_path = params[:controller].to_s.tr("/", "_")
        action = action_name

        custom_event_type = self.class.instance_variable_get(:@custom_audit_event_types)&.[](action.to_sym)
        return custom_event_type if custom_event_type

        singular_path = ActiveSupport::Inflector.singularize(controller_path)

        case action.to_sym
        when :index
          "read_#{controller_path}"
        when :show
          "show_#{singular_path}"
        when :create
          "create_#{controller_path}"
        when :update
          "update_#{singular_path}"
        when :destroy
          "destroy_#{singular_path}"
        else
          "#{action}_#{controller_path}"
        end
      end

      def skip_model_change_tracking?
        self.class.skip_model_change_tracking_actions.include?(action_name) ||
          (respond_to?(:skip_audit_logging?) && skip_audit_logging?)
      end

      def skip_audit_logging?
        self.class.skip_audit_logging_actions.include?(action_name)
      end

      def stringify_hash_values(data, seen = Set.new)
        case data
        when Hash
          return data if seen.include?(data.object_id)

          seen.add(data.object_id)
          data.transform_values { |value| stringify_hash_values(value, seen) }
        when Array
          return data if seen.include?(data.object_id)

          seen.add(data.object_id)
          data.map { |item| stringify_hash_values(item, seen) }
        when Numeric, TrueClass, FalseClass
          data.to_s
        when Date, Time, DateTime
          data.iso8601
        when NilClass, String
          data
        else
          begin
            stringify_hash_values(data.as_json, seen)
          rescue StandardError
            data.to_s
          end
        end
      end
    end
  end
end
