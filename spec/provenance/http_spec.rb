# frozen_string_literal: true

RSpec.describe "HTTP capture" do
  let(:user) { User.create!(email: "u@example.com", role: "manager") }
  let(:invoice) { Provenance.without { Invoice.create!(number: "7") } }
  let(:headers) { {"X-User-Id" => user.id.to_s, "User-Agent" => "rspec", "X-Request-Id" => "req-1"} }

  it "inserts the middleware right after ActionDispatch::RequestId" do
    stack = Rails.application.middleware.map(&:klass)
    expect(stack.index(Provenance::Middleware)).to eq(stack.index(ActionDispatch::RequestId) + 1)
  end

  it "emits one event per mutating request with request details and changes" do
    session.patch "/invoices/#{invoice.id}", params: {invoice: {status: "sent"}}, headers: headers

    expect(session.response.status).to eq(200)
    event = events.sole
    expect(event["action"]).to eq("kind" => "http", "name" => "invoices#update", "caused_by" => nil)
    expect(event["actor"]).to include("id" => user.id.to_s, "display" => "u@example.com", "roles" => ["manager"])
    expect(event["request"]).to eq(
      "id" => "req-1", "method" => "PATCH", "path" => "/invoices/#{invoice.id}", "status" => 200,
      "ip" => "127.0.0.1", "user_agent" => "rspec"
    )
    expect(event["changes"].sole).to include("entity" => "Invoice", "operation" => "update", "diff" => {"status" => %w[draft sent]})
    expect(schema_errors(event)).to be_empty
  end

  it "skips successful reads without changes" do
    session.get "/invoices", headers: headers
    session.get "/invoices/#{invoice.id}", headers: headers
    expect(events).to be_empty
  end

  it "emits reads that change data" do
    session.get "/invoices/#{invoice.id}/peek", headers: headers
    expect(events.sole["action"]["name"]).to eq("invoices#peek")
  end

  it "emits reads when audit_reads is on" do
    Provenance.config.audit_reads = true
    session.get "/invoices", headers: headers
    expect(events.sole["request"]["method"]).to eq("GET")
  end

  it "emits failed reads" do
    session.get "/invoices/0", headers: headers
    expect(events.sole["outcome"]).to include("result" => "failure")
    expect(events.sole["outcome"]["error"]["class"]).to eq("ActiveRecord::RecordNotFound")
    expect(events.sole["request"]["status"]).to eq(404)
  end

  it "emits mutating requests without changes" do
    session.post "/admin/reports", headers: headers
    expect(events.sole["changes"]).to eq([])
  end

  it "records unhandled exceptions as failure and keeps committed changes" do
    session.post "/invoices/#{invoice.id}/boom", headers: headers

    event = events.sole
    expect(session.response.status).to eq(500)
    expect(event["outcome"]["result"]).to eq("failure")
    expect(event["outcome"]["error"]["class"]).to eq("ArgumentError")
    expect(event["outcome"]["error"]["message"].length).to eq(500)
    expect(event["request"]["status"]).to eq(500)
    expect(event["changes"].sole["diff"]).to eq("status" => %w[draft exploding])
  end

  it "records denied exceptions" do
    session.post "/invoices/#{invoice.id}/forbidden", headers: headers
    expect(events.sole["outcome"]).to eq(
      "result" => "denied", "error" => {"class" => "Pundit::NotAuthorizedError", "message" => "not allowed"}
    )
  end

  it "treats a rescued 403 response as denied" do
    session.post "/invoices/#{invoice.id}/rescued_forbidden", headers: headers
    expect(events.sole["outcome"]).to eq("result" => "denied", "error" => nil)
  end

  it "honours skip_provenance per action" do
    session.post "/health", headers: headers
    expect(events).to be_empty
    expect(Note.count).to eq(1)
  end

  it "honours provenance_action_name" do
    session.post "/admin/reports/preview", headers: headers
    expect(events.sole["action"]["name"]).to eq("admin.reports.preview")
  end

  it "names requests that never reach a controller" do
    session.post "/nowhere", headers: headers
    expect(events.sole["action"]["name"]).to eq("POST /nowhere")
    expect(events.sole["request"]["status"]).to eq(404)
  end

  it "keeps annotations made in the controller" do
    session.patch "/invoices/#{invoice.id}", params: {invoice: {status: "paid"}, reason: "customer call"}, headers: headers
    expect(events.sole["metadata"]).to eq("reason" => "customer call")
  end

  it "records links made in the request" do
    session.post "/invoices/#{invoice.id}/tag", params: {name: "vip"}, headers: headers
    expect(events.sole["changes"].map { |c| c["operation"] }).to include("link")
  end

  it "does not let a failing sink break the request" do
    errors = []
    Provenance.config.on_error { |e, event| errors << [e, event] }
    Provenance.config.sink(:proc) { raise "sink down" }

    session.patch "/invoices/#{invoice.id}", params: {invoice: {status: "sent"}}, headers: headers

    expect(session.response.status).to eq(200)
    expect(errors.map { |e, _| e.message }).to eq(["sink down"])
    expect(errors.first.last["action"]["name"]).to eq("invoices#update")
    expect(events.size).to eq(1)
  end

  it "does nothing when disabled" do
    Provenance.config.enabled = false
    session.patch "/invoices/#{invoice.id}", params: {invoice: {status: "sent"}}, headers: headers
    expect(events).to be_empty
  end

  describe Provenance::Middleware do
    it "re-raises exceptions after recording them" do
      app = described_class.new(->(_env) { raise KeyError, "lost" })
      env = Rack::MockRequest.env_for("/x", method: "DELETE")
      expect { app.call(env) }.to raise_error(KeyError)
      expect(events.sole).to include("action" => include("name" => "DELETE /x"))
      expect(events.sole["outcome"]["error"]).to eq("class" => "KeyError", "message" => "lost")
    end

    it "passes through when an action is already open" do
      app = described_class.new(->(_env) { [204, {}, []] })
      Provenance.action("outer") { app.call(Rack::MockRequest.env_for("/x", method: "POST")) }
      expect(events.sole["action"]["name"]).to eq("outer")
    end
  end
end
