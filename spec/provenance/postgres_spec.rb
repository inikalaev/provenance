# frozen_string_literal: true

RSpec.describe "Outbox on PostgreSQL", if: Provenance::Outbox.postgresql? do
  let(:record_class) { Provenance::Outbox::Record }

  before do
    Provenance.config.outbox = true
    Provenance.config.outbox_enqueue_relay = false
  end

  it "allocates a gapless sequence under concurrent writers" do
    Provenance.config.integrity.key = "k"
    threads = Array.new(4) do |t|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          5.times { |i| Provenance.action("t#{t}-#{i}") {} }
        end
      end
    end
    threads.each(&:join)

    events = record_class.order(:seq).map(&:event)
    expect(events.map { |e| e["integrity"]["seq"] }).to eq((1..20).to_a)
    expect(Provenance::Integrity.verify(events, key: "k")).to be_nil
  end

  it "skips rows locked by another relay" do
    2.times { |i| Provenance.action("a#{i}") {} }
    entered = Queue.new
    release = Queue.new
    first_call = true
    Provenance.config.sink(:proc) do |_batch|
      if first_call
        first_call = false
        entered << true
        release.pop
      end
    end

    slow = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection { Provenance::Outbox::Relay.run(batch_size: 1) }
    end
    entered.pop
    fast = ActiveRecord::Base.connection_pool.with_connection { Provenance::Outbox::Relay.run(batch_size: 1) }
    release << true
    slow.join

    expect(fast).to eq(1)
    expect(events.map { |e| e["action"]["name"] }.sort).to eq(%w[a0 a1])
    expect(record_class.pluck(:status).uniq).to eq(["delivered"])
  end
end
