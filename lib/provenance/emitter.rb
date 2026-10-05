# frozen_string_literal: true

module Provenance
  # Turns closed actions into events and hands them to the outbox or the sinks.
  # Never raises: failures are reported through +on_error+.
  module Emitter
    module_function

    # Schedules emission of a closed action once every open transaction has committed.
    #
    # @param action [Action]
    # @return [void]
    def finish(action)
      return if action.skipped? || !Provenance.enabled?

      ActiveRecord.after_all_transactions_commit { emit(action) }
    rescue => e
      Provenance.config.report_error(e)
    end

    # Builds and dispatches the event for an action if it is auditable.
    #
    # @param action [Action]
    # @return [Hash, nil] the native event
    def emit(action)
      return unless action.auditable?

      event = Event.build(action)
      dispatch(event)
      event
    rescue => e
      Provenance.config.report_error(e, event)
      nil
    end

    # @param event [Hash] native event
    # @return [void]
    def dispatch(event)
      if Testing.capturing?
        Testing.record(event)
      elsif Provenance.config.outbox
        Outbox.write(event)
      else
        deliver([event])
      end
    end

    # Serializes native events in the configured format and delivers them to every
    # sink. A failing sink does not prevent delivery to the others.
    #
    # @param events [Array<Hash>] native events
    # @param raise_errors [Boolean] re-raise the first sink failure after trying all sinks
    # @return [void]
    def deliver(events, raise_errors: false)
      batch = Serializers.serialize_all(events, Provenance.config.format)
      failure = nil
      Provenance.config.sinks.each do |sink|
        sink.deliver(batch)
      rescue => e
        failure ||= e
        events.each { |event| Provenance.config.report_error(e, event) } unless raise_errors
      end
      raise failure if failure && raise_errors
    end
  end
end
