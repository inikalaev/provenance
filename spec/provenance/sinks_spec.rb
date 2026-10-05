# frozen_string_literal: true

RSpec.describe Provenance::Sinks do
  let(:batch) { [{"id" => "1", "n" => 1}, {"id" => "2", "n" => 2}] }

  it "builds sinks by type and accepts sink objects" do
    custom = Class.new { def deliver(_batch) = nil }.new
    expect(described_class.build(custom)).to be(custom)
    expect(described_class.build(:memory)).to be_a(Provenance::Sinks::Memory)
    expect { described_class.build(:carrier_pigeon) }.to raise_error(Provenance::ConfigurationError)
  end

  describe Provenance::Sinks::Logger do
    it "writes one JSON line per event" do
      io = StringIO.new
      described_class.new(logger: Logger.new(io, formatter: ->(*, msg) { "#{msg}\n" })).deliver(batch)
      expect(io.string.lines.map { |l| JSON.parse(l) }).to eq(batch)
    end

    it "defaults to the configured logger" do
      io = StringIO.new
      Provenance.config.logger = Logger.new(io)
      Provenance.config.sink :logger, level: :warn
      Provenance.action("logged") {}
      expect(io.string).to include("WARN").and include('"name":"logged"')
    end
  end

  describe Provenance::Sinks::IO do
    it "writes JSON lines to the IO" do
      io = StringIO.new
      described_class.new(io).deliver(batch)
      expect(io.string).to eq(%({"id":"1","n":1}\n{"id":"2","n":2}\n))
    end
  end

  describe Provenance::Sinks::Proc do
    it "calls a block or callable" do
      seen = []
      described_class.new { |b| seen << b }.deliver(batch)
      described_class.new(->(b) { seen << b.size }).deliver(batch)
      expect(seen).to eq([batch, 2])
      expect { described_class.new }.to raise_error(ArgumentError)
    end
  end

  describe Provenance::Sinks::Memory do
    it "stores and clears events" do
      sink = described_class.new
      sink.deliver(batch)
      expect(sink.events).to eq(batch)
      sink.clear
      expect(sink.events).to eq([])
    end
  end

  describe Provenance::Sinks::HTTP do
    let(:url) { "https://siem.example.com/ingest" }
    let(:delays) { [] }
    let(:sink) { described_class.new(url: url, headers: {"Authorization" => "Bearer t"}, retries: 2, sleeper: ->(s) { delays << s }) }

    it "POSTs the batch as a JSON array" do
      stub = stub_request(:post, url)
        .with(body: JSON.generate(batch), headers: {"Content-Type" => "application/json", "Authorization" => "Bearer t"})
        .to_return(status: 202)
      sink.deliver(batch)
      expect(stub).to have_been_requested.once
      expect(delays).to be_empty
    end

    it "retries non-2xx responses and network errors with backoff" do
      stub_request(:post, url).to_return({status: 503}).then.to_raise(Errno::ECONNREFUSED).then.to_return(status: 200)
      sink.deliver(batch)
      expect(delays.size).to eq(2)
      expect(delays[0]).to be_between(0.25, 0.5)
      expect(delays[1]).to be_between(0.5, 1.0)
    end

    it "raises DeliveryError when retries are exhausted" do
      stub_request(:post, url).to_return(status: 500)
      expect { sink.deliver(batch) }.to raise_error(Provenance::DeliveryError, /HTTP 500/)
      expect(a_request(:post, url)).to have_been_made.times(3)
    end

    it "caps the backoff" do
      capped = described_class.new(url: url, backoff: 10, max_backoff: 12)
      expect(capped.delay(5)).to be_between(6, 12)
    end

    it "rejects non-HTTP urls" do
      expect { described_class.new(url: "ftp://x") }.to raise_error(Provenance::ConfigurationError)
    end
  end

  describe "Kafka" do
    before do
      stubs = File.expand_path("../support/stubs", __dir__)
      $LOAD_PATH.unshift(stubs)
      require "provenance/sinks/kafka"
    ensure
      $LOAD_PATH.delete(stubs)
    end

    it "produces one message per event keyed by id" do
      producer = Rdkafka::FakeProducer.new
      sink = described_class.build(:kafka, topic: "audit", producer: producer)
      sink.deliver(batch)
      expect(producer.messages).to eq([
        {topic: "audit", payload: JSON.generate(batch[0]), key: "1"},
        {topic: "audit", payload: JSON.generate(batch[1]), key: "2"}
      ])
      expect(producer.waited).to eq(2)
      sink.close
      expect(producer.closed).to be(true)
    end

    it "builds a producer from config" do
      sink = Provenance::Sinks::Kafka.new(topic: "audit", config: {"bootstrap.servers": "k:9092"})
      expect(sink.instance_variable_get(:@producer)).to be_a(Rdkafka::FakeProducer)
    end
  end

  describe "failure isolation" do
    it "keeps delivering to other sinks and reports the failure" do
      errors = []
      Provenance.config.on_error { |e, event| errors << [e.message, event["id"]] }
      Provenance.config.sinks.unshift(Provenance::Sinks::Proc.new { raise "down" })
      Provenance.action("x") {}
      expect(events.size).to eq(1)
      expect(errors).to eq([["down", events.first["id"]]])
    end

    it "delivers in the configured format" do
      Provenance.config.format = :cloudevents
      Provenance.action("x") {}
      expect(events.sole["specversion"]).to eq("1.0")
    end
  end
end
