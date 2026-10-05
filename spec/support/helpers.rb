# frozen_string_literal: true

module SpecHelpers
  SCHEMA = JSONSchemer.schema(Pathname.new(File.expand_path("../../schema/event-2.json", __dir__)))

  def memory_sink
    Provenance.config.sinks.find { |s| s.is_a?(Provenance::Sinks::Memory) }
  end

  def events
    memory_sink.events
  end

  def session
    @session ||= ActionDispatch::Integration::Session.new(Rails.application)
  end

  def schema_errors(event)
    SCHEMA.validate(JSON.parse(JSON.generate(event))).map { |e| e["error"] }
  end

  def json_roundtrip(value)
    JSON.parse(JSON.generate(value))
  end
end
