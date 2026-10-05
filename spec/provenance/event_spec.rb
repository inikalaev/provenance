# frozen_string_literal: true

RSpec.describe Provenance::Event do
  let(:actor) { Provenance::Actor.new(id: 1, type: "User", display: "a@b.c", roles: ["admin"], impersonator: {id: 2, type: "User"}) }

  def build(**options)
    action = Provenance::Action.new(kind: :custom, name: "x", actor: actor, explicit: true, **options)
    yield action if block_given?
    described_class.build(action)
  end

  it "builds a deeply frozen event that matches the shipped JSON schema" do
    event = build(metadata: {at: Time.utc(2026, 1, 1), amount: BigDecimal("1.5"), list: [:a]}) do |action|
      action.add_change(Provenance::EntityChange.new(entity: "Invoice", entity_id: 7, operation: :update, diff: {"status" => %w[a b]}))
    end

    expect(schema_errors(event)).to be_empty
    expect(event).to be_frozen
    expect(event["changes"].first["diff"]["status"]).to be_frozen
    expect(event["metadata"]).to eq("at" => "2026-01-01T00:00:00.000Z", "amount" => "1.5", "list" => ["a"])
    expect(event["actor"]["impersonator"]).to include("id" => "2")
    expect(event["occurred_at"]).to match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z\z/)
  end

  it "redacts sensitive metadata keys" do
    event = build(metadata: {password: "x", nested: {secret: "y"}, ok: 1})
    expect(event["metadata"]).to eq("password" => "[REDACTED]", "nested" => {"secret" => "[REDACTED]"}, "ok" => 1)
  end

  it "rejects events missing required fields" do
    event = build.except("outcome")
    expect(schema_errors(event)).not_to be_empty
  end

  it "rejects unknown change operations" do
    expect { Provenance::EntityChange.new(entity: "X", operation: :merge) }.to raise_error(ArgumentError)
  end

  it "rejects unknown action kinds" do
    expect { Provenance::Action.new(kind: :cron, name: "x") }.to raise_error(ArgumentError)
  end
end

RSpec.describe Provenance::JsonSafe do
  it "converts values" do
    expect(described_class.call(Date.new(2026, 1, 2))).to eq("2026-01-02")
    expect(described_class.call(1.5)).to eq(1.5)
    expect(described_class.call(Float::NAN)).to eq("NaN")
    expect(described_class.call(5.minutes)).to eq("PT5M")
    expect(described_class.call("plain".b)).to eq("plain")
    expect(described_class.call("\xFF".dup.force_encoding("UTF-8"))).to eq("\uFFFD")
    expect(described_class.call(Set[1])).to eq([1])
    expect(described_class.call(Rational(1, 2))).to eq("1/2")
    expect(described_class.call(Object.new)).to be_a(Hash)
  end
end

RSpec.describe Provenance::UUID do
  it "generates time-ordered v7 ids" do
    a = described_class.v7(Time.at(1_000))
    b = described_class.v7(Time.at(2_000))
    expect(a).to start_with("0000000f-4240-7")
    expect(a < b).to be(true)
  end
end
