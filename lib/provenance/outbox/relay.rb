# frozen_string_literal: true

module Provenance
  module Outbox
    # Drains pending outbox rows in id order and delivers them to the sinks.
    module Relay
      # Upper bound for the retry delay, in seconds.
      MAX_BACKOFF = 3600

      module_function

      # Delivers due rows batch by batch until none are left or a batch fails, then
      # prunes old delivered rows.
      #
      # @param batch_size [Integer]
      # @return [Integer] number of delivered rows
      def run(batch_size: Provenance.config.outbox_batch_size)
        delivered = 0
        loop do
          count = Record.transaction { drain(batch_size) }
          break unless count&.positive?

          delivered += count
        end
        prune
        delivered
      end

      # Locks and delivers one batch. Stops at the first row that is not due yet so
      # rows are never delivered out of order.
      #
      # @api private
      # @return [Integer, nil] delivered rows, or nil when the batch failed
      def drain(batch_size)
        scope = Record.pending.order(:id).limit(batch_size)
        scope = scope.lock("FOR UPDATE SKIP LOCKED") if Outbox.postgresql?
        now = Time.current
        rows = scope.to_a.take_while { |row| row.next_attempt_at.nil? || row.next_attempt_at <= now }
        return 0 if rows.empty?

        begin
          Emitter.deliver(rows.map(&:event), raise_errors: true)
        rescue => e
          fail_rows(rows, e, now)
          return nil
        end
        Record.where(id: rows.map(&:id)).update_all(status: Record::DELIVERED, delivered_at: now, last_error: nil)
        rows.size
      end

      # @api private
      def fail_rows(rows, error, now)
        rows.each do |row|
          attempts = row.attempts.to_i + 1
          row.update_columns(
            attempts: attempts, next_attempt_at: now + backoff(attempts),
            last_error: "#{error.class}: #{error.message}".truncate(1000)
          )
        end
        Provenance.config.report_error(error)
      end

      # @param attempts [Integer]
      # @return [Float] seconds until the next attempt
      def backoff(attempts)
        base = [5 * (2**(attempts - 1)), MAX_BACKOFF].min
        base + rand * base * 0.2
      end

      # Deletes delivered rows older than +outbox_retention+, keeping the newest row
      # of each app as the anchor of the integrity chain.
      #
      # @return [Integer] deleted rows
      def prune
        cutoff = Time.current - Provenance.config.outbox_retention
        anchors = Record.group(:app).maximum(:id).values
        Record.delivered.where(delivered_at: ...cutoff).where.not(id: anchors).delete_all
      end
    end
  end
end
