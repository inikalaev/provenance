# frozen_string_literal: true

RSpec.describe Provenance::Outbox do
  include ActiveJob::TestHelper

  let(:record_class) { Provenance::Outbox::Record }

  before { Provenance.config.outbox = true }

  it "writes events to the outbox instead of the sinks and enqueues the relay" do
    Provenance.action("a") { Invoice.create!(number: "1") }

    expect(events).to be_empty
    row = record_class.sole
    expect(row).to have_attributes(app: "dummy", status: "pending", attempts: 0, seq: nil, mac: nil)
    expect(row.event["action"]["name"]).to eq("a")
    expect(row.event_id).to eq(row.event["id"])
    expect(enqueued_jobs.map { |j| j["job_class"] }).to eq(["Provenance::RelayJob"])
  end

  it "can skip enqueuing the relay" do
    Provenance.config.outbox_enqueue_relay = false
    Provenance.action("a") {}
    expect(enqueued_jobs).to be_empty
  end

  describe Provenance::Outbox::Relay do
    it "delivers pending rows in order and marks them delivered" do
      3.times { |i| Provenance.action("a#{i}") {} }
      expect(described_class.run(batch_size: 2)).to eq(3)

      expect(events.map { |e| e["action"]["name"] }).to eq(%w[a0 a1 a2])
      expect(record_class.pluck(:status).uniq).to eq(["delivered"])
      expect(record_class.where(delivered_at: nil)).to be_empty
    end

    it "serializes in the configured format at delivery time" do
      Provenance.action("a") {}
      Provenance.config.format = :cloudevents
      described_class.run
      expect(events.sole["type"]).to eq("provenance.action.custom")
    end

    it "keeps failed rows pending with backoff and stops to preserve order" do
      errors = []
      Provenance.config.on_error { |e, _| errors << e.message }
      failing = true
      Provenance.config.sink(:proc) { raise "down" if failing }
      2.times { |i| Provenance.action("a#{i}") {} }

      expect(described_class.run(batch_size: 1)).to eq(0)
      first, second = record_class.order(:id).to_a
      expect(first).to have_attributes(status: "pending", attempts: 1, last_error: "RuntimeError: down")
      expect(first.next_attempt_at).to be > Time.current
      expect(second.attempts).to eq(0)
      expect(errors).to eq(["down"])

      failing = false
      expect(described_class.run).to eq(0)
      first.update_columns(next_attempt_at: 1.second.ago)
      expect(described_class.run).to eq(2)
      expect(events.map { |e| e["action"]["name"] }).to eq(%w[a0 a0 a1])
    end

    it "grows the backoff exponentially" do
      expect(described_class.backoff(1)).to be_between(5, 6)
      expect(described_class.backoff(3)).to be_between(20, 24)
      expect(described_class.backoff(30)).to be_between(3600, 4320)
    end

    it "prunes delivered rows past retention but keeps the newest row per app" do
      3.times { Provenance.action("a") {} }
      described_class.run
      record_class.update_all(delivered_at: 8.days.ago)
      described_class.prune
      expect(record_class.count).to eq(1)
      expect(record_class.sole.id).to eq(record_class.maximum(:id))
    end

    it "keeps recent and pending rows" do
      Provenance.action("a") {}
      described_class.run
      Provenance.action("b") {}
      expect(described_class.prune).to eq(0)
      expect(record_class.count).to eq(2)
    end
  end

  describe Provenance::RelayJob do
    it "drains the outbox and is not audited itself" do
      Provenance.action("a") {}
      perform_enqueued_jobs
      expect(events.map { |e| e["action"]["name"] }).to eq(["a"])
      expect(record_class.sole.status).to eq("delivered")
    end
  end
end
