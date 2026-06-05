# frozen_string_literal: true

require "active_support/concern"
require "active_support/inflector"

module Provenance
  # Controller-side concern that emits a dedicated audit event for failed
  # requests. Call `audit_error(error, status)` from your error handlers.
  module ErrorReporting
    extend ActiveSupport::Concern
    include Provenance::Trackers::Providers

    STATUS_CODES = {
      not_found: 404,
      unauthorized: 401,
      forbidden: 403,
      unprocessable_entity: 422,
      conflict: 409
    }.freeze

    def audit_error(error_message, status)
      return if skip_audit_logging? || !Provenance.config.enabled

      numeric_status = status.is_a?(Symbol) ? STATUS_CODES[status] || 500 : status

      audit_data = {
        timestamp: Time.current.utc.iso8601(3),
        event_type: generate_event_type,
        status: numeric_status.to_s,
        message: stringify_hash_values({
          error_type: error_message.class.name,
          error_message: error_message.is_a?(Exception) ? error_message.message : error_message.to_s,
          params: filter_sensitive_params(params.to_unsafe_h)
        }),
        username: username_from_provider || "unauthenticated",
        remote_ip: remote_ip_from_provider || "unknown",
        origin_ip: origin_ip_from_provider || "unknown",
        session_id: session_id_from_provider || "unauthenticated",
        roles: roles_from_provider || [],
        source: Provenance.config.source_name
      }.compact

      Provenance.config.audit_hooks.each do |hook|
        hook.call(audit_data)
      end
    end
  end
end
