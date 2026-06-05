# frozen_string_literal: true

require "active_support/concern"
require "action_controller"
require "active_record"

module Provenance
  # Controller-side concern. Wraps each action, opens a journal, collects model
  # changes for the request and delivers the assembled audit event to the
  # configured hooks once all transactions have completed.
  module Auditable
    extend ActiveSupport::Concern
    include Provenance::Trackers::Providers

    included do
      around_action :track_model_changes
    end

    private

    def track_model_changes
      return yield if skip_model_change_tracking? || !Provenance.config.enabled

      Provenance::Context.journal = Provenance::Journal.new

      Provenance::Context.pending_audit_log = -> do
        next unless Provenance::Context.request_completed?

        status = Provenance::Context.response_status
        next if status && status >= 400

        log_audit_event_and_clear_journal
      end

      request_obj = request
      if request_obj.respond_to?(:uuid)
        uuid_value = request_obj.uuid
        Provenance::Context.request_id = uuid_value.to_s if uuid_value && !uuid_value.to_s.strip.empty?
      end

      Thread.current[:provenance_send_scheduled] = nil

      yield

      Provenance::Context.response_status = if response.respond_to?(:status)
                                              response.status
                                            else
                                              200
                                            end

      send_audit_after_all_commits
    end

    def send_audit_after_all_commits
      return unless Provenance.config.enabled

      journal = Provenance::Context.journal
      return unless journal

      active_transactions = journal.instance_variable_get(:@active_transactions)

      return if active_transactions.any?

      send_audit_if_ready
    end

    def send_audit_if_ready
      return unless Provenance.config.enabled

      journal = Provenance::Context.journal

      if request.respond_to?(:get?) && (request.get? || request.head?)
        log_audit_event_and_clear_journal
        return
      end

      return unless journal&.all_transactions_completed?

      log_audit_event_and_clear_journal
    end

    def log_audit_event_and_clear_journal
      return if skip_audit_logging? || !Provenance.config.enabled

      journal = Provenance::Context.journal
      return unless journal

      begin
        audit_data = audit_log_data

        Provenance.config.audit_hooks.each do |hook|
          hook.call(audit_data)
        end
      ensure
        Provenance::Context.cleanup
      end
    end

    def audit_log_data
      journal_data = Provenance::Context.journal&.to_h

      response_status = response.respond_to?(:status) ? response.status : 200

      message_data = if response_status < 400
                       (journal_data || {}).merge(params: filter_sensitive_params(params.to_unsafe_h))
                     else
                       filter_sensitive_params(params.to_unsafe_h)
                     end

      {
        timestamp: Time.current.utc.iso8601(3),
        event_type: generate_event_type,
        status: response_status,
        message: stringify_hash_values(message_data),
        username: username_from_provider || "unauthenticated",
        remote_ip: remote_ip_from_provider || "unknown",
        origin_ip: origin_ip_from_provider || "unknown",
        session_id: session_id_from_provider || "unauthenticated",
        roles: roles_from_provider || [],
        request_id: Provenance::Context.request_id,
        source: Provenance.config.source_name
      }.compact
    end
  end
end
