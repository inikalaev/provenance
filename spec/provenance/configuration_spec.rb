# frozen_string_literal: true

RSpec.describe Provenance::Configuration do
  subject(:config) { described_class.new }

  it "has the documented defaults" do
    expect(config.enabled).to be(true)
    expect(config.format).to eq(:native)
    expect(config.outbox).to be(false)
    expect(config.outbox_retention).to eq(7.days)
    expect(config.audit_reads).to be(false)
    expect(config.denied_exceptions).to eq(["CanCan::AccessDenied", "Pundit::NotAuthorizedError"])
    expect(config.bulk_ids_limit).to eq(500)
    expect(config.integrity.key).to be_nil
    expect(config.sinks).to eq([])
  end

  it "derives app_name from the Rails application module" do
    expect(config.app_name).to eq("dummy")
  end

  it "rejects an unknown format" do
    config.format = :xml
    expect { config.validate! }.to raise_error(Provenance::ConfigurationError, /format/)
  end

  it "requires the outbox for integrity" do
    config.integrity.key = "secret"
    expect { config.validate! }.to raise_error(Provenance::ConfigurationError, /outbox/)
    config.outbox = true
    expect(config.validate!).to be(true)
  end

  it "rejects a negative bulk_ids_limit" do
    config.bulk_ids_limit = -1
    expect { config.validate! }.to raise_error(Provenance::ConfigurationError)
  end

  it "validates inside Provenance.configure" do
    expect { Provenance.configure { |c| c.format = :yaml } }.to raise_error(Provenance::ConfigurationError)
  end

  it "matches denied exceptions by ancestor name" do
    stub_const("CanCan::AccessDenied", Class.new(StandardError))
    subclass = Class.new(CanCan::AccessDenied)
    expect(config.denied?(subclass.new)).to be(true)
    expect(config.denied?(RuntimeError.new)).to be(false)
  end

  it "reports errors through on_error" do
    seen = []
    config.on_error { |e, event| seen << [e.message, event] }
    config.report_error(RuntimeError.new("x"), {"id" => "1"})
    expect(seen).to eq([["x", {"id" => "1"}]])
  end

  it "logs errors by default" do
    io = StringIO.new
    config.logger = Logger.new(io)
    config.report_error(RuntimeError.new("sink down"))
    expect(io.string).to include("RuntimeError: sink down")
  end

  it "survives a failing error handler" do
    io = StringIO.new
    config.logger = Logger.new(io)
    config.on_error { raise "handler broke" }
    expect { config.report_error(RuntimeError.new("x")) }.not_to raise_error
    expect(io.string).to include("handler broke")
  end

  it "merges redact_attributes with += semantics" do
    config.redact_attributes += %i[iban]
    expect(config.redact_attributes).to eq([:iban])
  end
end
