# frozen_string_literal: true

RSpec.describe "Provenance.action" do
  let(:admin) { User.create!(email: "admin@example.com", role: "admin") }

  it "emits an explicit action even without changes" do
    result = Provenance.action("users.import", actor: admin, metadata: {file: "x.csv"}) { 42 }

    expect(result).to eq(42)
    expect(events.size).to eq(1)
    event = events.first
    expect(event["action"]).to eq("kind" => "custom", "name" => "users.import", "caused_by" => nil)
    expect(event["actor"]).to include("id" => admin.id.to_s, "type" => "User", "display" => "admin@example.com", "roles" => ["admin"])
    expect(event["metadata"]).to eq("file" => "x.csv")
    expect(event["outcome"]).to eq("result" => "success", "error" => nil)
    expect(event["request"]).to be_nil
    expect(schema_errors(event)).to be_empty
  end

  it "collects changes made inside the block" do
    Provenance.action("invoices.batch") do
      Invoice.create!(number: "A-1")
      Invoice.create!(number: "A-2")
    end

    expect(events.size).to eq(1)
    expect(events.first["changes"].map { |c| c["diff"]["number"] }).to eq(%w[A-1 A-2])
  end

  it "attaches nested scopes to the outermost action" do
    Provenance.action("outer") do
      Invoice.create!(number: "1")
      Provenance.action("inner", metadata: {step: 2}) { Invoice.create!(number: "2") }
    end

    expect(events.size).to eq(1)
    expect(events.first["action"]["name"]).to eq("outer")
    expect(events.first["changes"].size).to eq(2)
    expect(events.first["metadata"]).to eq("step" => 2)
  end

  it "exposes the current action for annotation and actor changes" do
    Provenance.action("x") do
      expect(Provenance.current).to be_a(Provenance::Action)
      Provenance.current.annotate(reason: "GDPR request #42")
      Provenance.current.actor = admin
    end

    expect(Provenance.current).to be_nil
    expect(events.first["metadata"]).to eq("reason" => "GDPR request #42")
    expect(events.first["actor"]["id"]).to eq(admin.id.to_s)
  end

  it "records failures with a truncated message and re-raises" do
    expect { Provenance.action("x") { raise ArgumentError, "a" * 600 } }.to raise_error(ArgumentError)

    outcome = events.first["outcome"]
    expect(outcome["result"]).to eq("failure")
    expect(outcome["error"]["class"]).to eq("ArgumentError")
    expect(outcome["error"]["message"].length).to eq(500)
  end

  it "records denied exceptions and re-raises" do
    expect { Provenance.action("x") { raise Pundit::NotAuthorizedError, "no" } }.to raise_error(Pundit::NotAuthorizedError)

    expect(events.first["outcome"]).to eq(
      "result" => "denied", "error" => {"class" => "Pundit::NotAuthorizedError", "message" => "no"}
    )
  end

  it "requires a block" do
    expect { Provenance.action("x") }.to raise_error(ArgumentError)
  end

  it "uses UUIDv7 ids" do
    Provenance.action("x") {}
    expect(events.first["id"]).to match(/\A\h{8}-\h{4}-7\h{3}-[89ab]\h{3}-\h{12}\z/)
  end

  it "does nothing when disabled" do
    Provenance.config.enabled = false
    Provenance.action("x") { Invoice.create!(number: "1") }
    expect(events).to be_empty
  end

  it "keeps action state per thread" do
    seen = nil
    Provenance.action("main") do
      Thread.new { seen = Provenance.current }.join
    end
    expect(seen).to be_nil
  end

  describe "implicit actions" do
    it "wraps changes outside any action into Model.operation actions" do
      invoice = Invoice.create!(number: "1")
      invoice.update!(status: "sent")
      invoice.destroy!

      expect(events.map { |e| e["action"]["name"] }).to eq(%w[Invoice.create Invoice.update Invoice.destroy])
      expect(events.map { |e| e["action"]["kind"] }.uniq).to eq(["custom"])
    end
  end

  describe "Provenance.without" do
    it "suppresses tracking inside the block" do
      value = Provenance.without do
        Invoice.create!(number: "1")
        Provenance.action("hidden") { :ok }
      end

      expect(value).to eq(:ok)
      expect(events).to be_empty
      expect(Provenance.suppressed?).to be(false)
    end

    it "suppresses only part of an action" do
      Provenance.action("partial") do
        Invoice.create!(number: "tracked")
        Provenance.without { Invoice.create!(number: "hidden") }
      end

      expect(events.first["changes"].map { |c| c["diff"]["number"] }).to eq(["tracked"])
    end
  end

  describe "actor resolution" do
    it "uses the configured resolver when no actor is given" do
      Provenance.config.actor { |_ctx| {id: 7, type: "Service", display: "cron"} }
      Provenance.action("x") {}
      expect(events.first["actor"]).to include("id" => "7", "type" => "Service", "display" => "cron")
    end

    it "reports resolver failures and emits without an actor" do
      errors = []
      Provenance.config.on_error { |e, _| errors << e }
      Provenance.config.actor { |_ctx| raise "no session" }
      Provenance.action("x") {}

      expect(events.first["actor"]).to be_nil
      expect(errors.map(&:message)).to eq(["no session"])
    end
  end
end
