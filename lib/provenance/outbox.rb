# frozen_string_literal: true

module Provenance
  # Reliable delivery: events are stored in the +provenance_outbox+ table and
  # delivered by {RelayJob}.
  module Outbox
    autoload :Record, "provenance/outbox/record"
    autoload :Relay, "provenance/outbox/relay"

    # Attempts made to allocate a sequence number before giving up.
    WRITE_ATTEMPTS = 5

    module_function

    # Stores a native event, adding the integrity chain when a key is configured.
    #
    # @param event [Hash] native event
    # @return [Record]
    def write(event)
      attempts = 0
      begin
        attempts += 1
        record = Record.transaction(requires_new: true) { insert(event) }
      rescue ActiveRecord::RecordNotUnique
        retry if attempts < WRITE_ATTEMPTS
        raise
      end
      RelayJob.perform_later if Provenance.config.outbox_enqueue_relay
      record
    end

    # @api private
    def insert(event)
      app = event["app"]
      key = Provenance.config.integrity.key
      seq = mac = nil
      if key.present?
        lock(app)
        last_seq, prev = Record.where(app: app).where.not(seq: nil).order(seq: :desc).pick(:seq, :mac)
        seq = last_seq.to_i + 1
        mac = Integrity.mac(key, prev, event)
        event = event.merge("integrity" => {"seq" => seq, "prev" => prev, "mac" => mac})
      end
      Record.create!(
        app: app, event_id: event["id"], seq: seq, mac: mac, payload: JSON.generate(event),
        status: Record::PENDING, attempts: 0, next_attempt_at: Time.current
      )
    end

    # Serializes sequence allocation per app on PostgreSQL. Other databases rely on
    # the unique (app, seq) index and a retry.
    #
    # @api private
    def lock(app)
      return unless postgresql?

      Record.connection.execute(
        Record.sanitize_sql_array(["SELECT pg_advisory_xact_lock(hashtext(?))", "provenance:#{app}"])
      )
    end

    # @return [Boolean]
    def postgresql?
      Record.connection_db_config.adapter.to_s.match?(/postg/i)
    end
  end
end
