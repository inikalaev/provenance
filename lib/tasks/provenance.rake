# frozen_string_literal: true

namespace :provenance do
  desc "Verify the integrity chain of events stored in the outbox"
  task verify: :environment do
    key = Provenance.config.integrity.key
    abort "provenance:verify: integrity.key is not configured" if key.blank?

    broken = Provenance::Outbox::Record.where.not(seq: nil).distinct.pluck(:app).filter_map do |app|
      events = Provenance::Outbox::Record.where(app: app).where.not(seq: nil).order(:seq).map(&:event)
      seq = Provenance::Integrity.verify(events, key: key)
      puts "#{app}: #{seq ? "broken at seq #{seq}" : "ok (#{events.size} events)"}"
      seq
    end
    abort "provenance:verify: integrity check failed" if broken.any?
  end

  desc "Deliver pending outbox events now"
  task relay: :environment do
    puts "delivered #{Provenance::Outbox::Relay.run} events"
  end
end
