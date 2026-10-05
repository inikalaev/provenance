# frozen_string_literal: true

require "rake"

RSpec.describe Provenance::Integrity do
  let(:key) { "k" * 32 }

  before do
    Provenance.config.outbox = true
    Provenance.config.outbox_enqueue_relay = false
    Provenance.config.integrity.key = key
  end

  def stored
    Provenance::Outbox::Record.order(:seq).map(&:event)
  end

  it "chains events with seq, prev and mac" do
    3.times { |i| Provenance.action("a#{i}") {} }

    chain = stored.map { |e| e["integrity"] }
    expect(chain.map { |i| i["seq"] }).to eq([1, 2, 3])
    expect(chain.first["prev"]).to be_nil
    expect(chain[1]["prev"]).to eq(chain[0]["mac"])
    expect(chain[2]["prev"]).to eq(chain[1]["mac"])
    expect(stored.map { |e| schema_errors(e) }.flatten).to be_empty
    expect(Provenance::Outbox::Record.order(:seq).pluck(:mac)).to eq(chain.map { |i| i["mac"] })
  end

  it "computes the mac over prev and the canonical event without integrity" do
    Provenance.action("a") {}
    event = stored.first
    canonical = described_class.canonical(event.except("integrity"))
    expect(canonical).not_to include(" ")
    expect(event["integrity"]["mac"]).to eq(OpenSSL::HMAC.hexdigest("SHA256", key, canonical))
  end

  it "produces canonical JSON with sorted keys" do
    expect(described_class.canonical({"b" => 1, :a => {"d" => [{"z" => 1, "y" => 2}], "c" => nil}}))
      .to eq('{"a":{"c":null,"d":[{"y":2,"z":1}]},"b":1}')
  end

  it "verifies an intact chain" do
    3.times { Provenance.action("a") {} }
    expect(described_class.verify(stored, key: key)).to be_nil
    expect(described_class.verify(stored.drop(1), key: key)).to be_nil
  end

  it "returns the first broken seq on tampering" do
    3.times { Provenance.action("a") {} }
    events = stored
    events[1]["metadata"] = {"forged" => true}
    expect(described_class.verify(events, key: key)).to eq(2)
  end

  it "detects removed and reordered events" do
    3.times { Provenance.action("a") {} }
    expect(described_class.verify(stored.values_at(0, 2), key: key)).to eq(3)
    expect(described_class.verify(stored.values_at(1, 0), key: key)).to eq(1)
  end

  it "detects a wrong key and a missing integrity block" do
    Provenance.action("a") {}
    expect(described_class.verify(stored, key: "other")).to eq(1)
    expect(described_class.verify([stored.first.except("integrity")], key: key)).to eq(0)
  end

  it "keeps the chain across pruning" do
    2.times { Provenance.action("a") {} }
    Provenance::Outbox::Relay.run
    Provenance::Outbox::Record.update_all(delivered_at: 30.days.ago)
    Provenance::Outbox::Relay.prune
    Provenance.action("b") {}
    expect(stored.map { |e| e["integrity"]["seq"] }).to eq([2, 3])
    expect(described_class.verify(stored, key: key)).to be_nil
  end

  it "retries sequence allocation on a unique violation" do
    Provenance.action("a") {}
    calls = 0
    allow(Provenance::Outbox::Record).to receive(:create!).and_wrap_original do |original, **attrs|
      calls += 1
      raise ActiveRecord::RecordNotUnique, "dup" if calls == 1

      original.call(**attrs)
    end
    Provenance.action("b") {}
    expect(calls).to eq(2)
    expect(stored.map { |e| e["integrity"]["seq"] }).to eq([1, 2])
  end

  describe "rake provenance:verify" do
    before do
      Rake.application = Rake::Application.new
      Rake::Task.define_task(:environment)
      load File.expand_path("../../lib/tasks/provenance.rake", __dir__)
    end

    it "passes for an intact outbox" do
      2.times { Provenance.action("a") {} }
      expect { Rake::Task["provenance:verify"].invoke }.to output(/dummy: ok \(2 events\)/).to_stdout
    end

    it "fails for a tampered outbox" do
      2.times { Provenance.action("a") {} }
      row = Provenance::Outbox::Record.order(:seq).last
      row.update_columns(payload: row.payload.sub('"name":"a"', '"name":"b"'))
      expect { Rake::Task["provenance:verify"].invoke }
        .to output(/broken at seq 2/).to_stdout
        .and output(/integrity check failed/).to_stderr
        .and raise_error(SystemExit)
    end

    it "relays pending events" do
      Provenance.action("a") {}
      expect { Rake::Task["provenance:relay"].invoke }.to output(/delivered 1 events/).to_stdout
    end
  end
end
