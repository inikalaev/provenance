# frozen_string_literal: true

RSpec.describe Provenance::Serializers do
  let(:event) do
    json_roundtrip(
      "schema" => "provenance/event@2",
      "id" => "0192f5c6-0000-7000-8000-000000000001",
      "occurred_at" => "2026-10-05T12:00:00.123Z",
      "app" => "billing",
      "action" => {"kind" => "http", "name" => "invoices#update", "caused_by" => nil},
      "actor" => {"id" => "42", "type" => "User", "display" => "a@b.c", "roles" => ["admin"], "impersonator" => nil},
      "request" => {"id" => "r1", "method" => "PATCH", "path" => "/invoices/7", "status" => 200, "ip" => "10.0.0.1", "user_agent" => "curl"},
      "outcome" => {"result" => "success", "error" => nil},
      "changes" => [
        {"entity" => "Invoice", "entity_id" => "7", "operation" => "update", "diff" => {"status" => %w[draft sent]}},
        {"entity" => "Invoice", "entity_id" => "7", "operation" => "link", "diff" => nil, "association" => "tags", "target" => {"type" => "Tag", "id" => "1"}}
      ],
      "metadata" => {"reason" => "x"}
    )
  end

  it "returns native events unchanged" do
    expect(described_class.serialize_all([event], :native)).to eq([event])
  end

  it "raises on an unknown format" do
    expect { described_class.for(:xml) }.to raise_error(Provenance::ConfigurationError)
  end

  describe "CloudEvents" do
    it "wraps the native event as data" do
      ce = described_class.serialize_all([event], :cloudevents).sole
      expect(ce).to include(
        "specversion" => "1.0", "id" => event["id"], "source" => "billing", "type" => "provenance.action.http",
        "time" => "2026-10-05T12:00:00.123Z", "datacontenttype" => "application/json", "subject" => "invoices#update"
      )
      expect(ce["data"]).to eq(event)
    end
  end

  describe "OCSF" do
    let(:serialized) { described_class.serialize_all([event], :ocsf) }
    let(:api) { serialized.first }

    it "maps the action to API Activity (6003)" do
      expect(api).to include(
        "class_uid" => 6003, "category_uid" => 6, "activity_id" => 3, "activity_name" => "Update",
        "type_uid" => 600303, "time" => 1_791_201_600_123, "status_id" => 1, "status" => "Success", "severity_id" => 1
      )
      expect(api["actor"]["user"]).to eq("uid" => "42", "name" => "a@b.c", "type" => "User", "groups" => [{"name" => "admin"}])
      expect(api["api"]).to eq("operation" => "invoices#update", "request" => {"uid" => "r1"}, "response" => {"code" => 200})
      expect(api["src_endpoint"]).to eq("ip" => "10.0.0.1")
      expect(api["http_request"]).to eq("http_method" => "PATCH", "url" => {"path" => "/invoices/7"}, "user_agent" => "curl", "uid" => "r1")
      expect(api["metadata"]).to include("version" => "1.3.0", "uid" => event["id"], "correlation_uid" => event["id"])
      expect(api["metadata"]["product"]).to include("name" => "Provenance")
      expect(api["unmapped"]["action"]).to eq(event["action"])
    end

    it "maps each change to Entity Management (3004)" do
      update, link = serialized.drop(1)
      expect(update).to include("class_uid" => 3004, "category_uid" => 3, "activity_id" => 3, "type_uid" => 300403)
      expect(update["entity"]).to eq("name" => "Invoice", "type" => "Invoice", "uid" => "7", "data" => {"status" => %w[draft sent]})
      expect(update["metadata"]).to include("uid" => "#{event["id"]}/0", "correlation_uid" => event["id"])
      expect(link).to include("activity_id" => 99, "activity_name" => "Link", "type_uid" => 300499)
      expect(link["unmapped"]["change"]).to include("association" => "tags")
    end

    it "maps failures and non-HTTP actions" do
      failed = event.merge(
        "action" => {"kind" => "job", "name" => "X", "caused_by" => nil}, "request" => nil, "actor" => nil,
        "outcome" => {"result" => "denied", "error" => {"class" => "E", "message" => "m"}},
        "changes" => [event["changes"].first]
      )
      api = described_class::OCSF.api_activity(failed)
      expect(api).to include("activity_id" => 3, "status_id" => 2, "status_detail" => "denied", "severity_id" => 3)
      expect(api["api"]["response"]).to eq("error" => "E", "error_message" => "m")
      expect(api).not_to have_key("http_request")
      expect(api["actor"]).to eq("app_name" => "billing")
    end
  end
end
