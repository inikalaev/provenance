# frozen_string_literal: true

RSpec.describe Provenance::Testing do
  let(:invoice) { Provenance.without { Invoice.create!(number: "1") } }

  it "captures events even when disabled, bypassing sinks and outbox" do
    Provenance.config.enabled = false
    Provenance.config.outbox = true
    captured = described_class.capture { Provenance.action("x") { invoice.update!(status: "sent") } }

    expect(captured.size).to eq(1)
    expect(events).to be_empty
    expect(Provenance::Outbox::Record.count).to eq(0)
    expect(described_class.capturing?).to be(false)
  end

  it "supports nested captures" do
    inner = nil
    outer = described_class.capture do
      Provenance.action("a") {}
      inner = described_class.capture { Provenance.action("b") {} }
    end
    expect(outer.map { |e| e["action"]["name"] }).to eq(%w[a b])
    expect(inner.map { |e| e["action"]["name"] }).to eq(%w[b])
  end

  describe "emit_provenance_event" do
    it "matches action, outcome and changes with composable matchers" do
      expect { session.patch "/invoices/#{invoice.id}", params: {invoice: {status: "sent"}} }
        .to emit_provenance_event(action: "invoices#update", outcome: "success")
        .with_change(entity: "Invoice", operation: "update", diff: including(status: ["draft", "sent"]))
    end

    it "matches by other attributes" do
      expect { Provenance.action("x", metadata: {a: 1}) {} }
        .to emit_provenance_event(kind: "custom", metadata: {"a" => 1}).once
    end

    it "supports not_to without arguments" do
      expect { session.get "/invoices" }.not_to emit_provenance_event
    end

    it "supports not_to with arguments" do
      expect { Provenance.action("x") {} }.not_to emit_provenance_event(action: "y")
    end

    it "fails with a helpful message" do
      matcher = emit_provenance_event(action: "nope").with_change(entity: "Invoice")
      expect(matcher.matches?(-> { Provenance.action("x") {} })).to be(false)
      expect(matcher.failure_message).to include("emit provenance event").and include('"name":"x"')
      expect(matcher.description).to include("with change")
    end

    it "counts exact matches" do
      matcher = emit_provenance_event(kind: "custom").exactly(2)
      expect(matcher.matches?(-> { Provenance.action("x") {} })).to be(false)
      expect { 2.times { Provenance.action("x") {} } }.to emit_provenance_event(kind: "custom").exactly(2)
    end

    it "rejects unknown keys" do
      expect { emit_provenance_event(bogus: 1) }.to raise_error(ArgumentError)
    end

    it "explains negative failures" do
      matcher = emit_provenance_event(action: "x")
      expect(matcher.does_not_match?(-> { Provenance.action("x") {} })).to be(false)
      expect(matcher.failure_message_when_negated).to include("not to emit")
    end
  end
end
