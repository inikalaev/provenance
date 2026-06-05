# frozen_string_literal: true

require "securerandom"

module Provenance
  # Per-request scratch space backed by fiber-local storage. Holds the active
  # journal, the deferred delivery callback and the request/response metadata
  # for the duration of a single request.
  class Context
    class << self
      def journal
        Thread.current[:provenance_journal]
      end

      def journal=(value)
        Thread.current[:provenance_journal] = value
      end

      def pending_audit_log
        Thread.current[:provenance_pending_log]
      end

      def pending_audit_log=(callback)
        Thread.current[:provenance_pending_log] = callback
      end

      def request_id
        Thread.current[:provenance_request_id]
      end

      def request_id=(value)
        Thread.current[:provenance_request_id] = value
      end

      def response_status
        Thread.current[:provenance_response_status]
      end

      def response_status=(value)
        Thread.current[:provenance_response_status] = value
        Thread.current[:provenance_request_completed] = true
      end

      def request_completed?
        Thread.current[:provenance_request_completed] || false
      end

      def cleanup
        Thread.current[:provenance_journal] = nil
        Thread.current[:provenance_pending_log] = nil
        Thread.current[:provenance_request_id] = nil
        Thread.current[:provenance_send_scheduled] = nil
        Thread.current[:provenance_response_status] = nil
        Thread.current[:provenance_request_completed] = nil
      end
    end
  end
end
