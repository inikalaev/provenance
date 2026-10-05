# frozen_string_literal: true

RSpec.describe Provenance::Actor do
  it "wraps records" do
    user = User.create!(email: "a@b.c", role: "admin")
    expect(described_class.wrap(user).to_h).to eq(
      "id" => user.id.to_s, "type" => "User", "display" => "a@b.c", "roles" => ["admin"], "impersonator" => nil
    )
  end

  it "wraps hashes with an impersonator" do
    actor = described_class.wrap(id: 1, type: "User", roles: [:support], impersonator: {id: 2, type: "Admin"})
    expect(actor.roles).to eq(["support"])
    expect(actor.impersonator.to_h).to include("id" => "2", "type" => "Admin")
  end

  it "prefers provenance_actor and provenance_display" do
    custom = Struct.new(:id) do
      def provenance_display = "custom"
    end
    expect(described_class.wrap(custom.new(5)).display).to eq("custom")

    with_hash = Struct.new(:id) do
      def provenance_actor = {id: "svc", type: "Service"}
    end
    expect(described_class.wrap(with_hash.new(1)).id).to eq("svc")
  end

  it "passes actors and nil through" do
    actor = described_class.new(id: 1)
    expect(described_class.wrap(actor)).to be(actor)
    expect(described_class.wrap(nil)).to be_nil
  end

  it "compares by value" do
    expect(described_class.new(id: 1, type: "User")).to eq(described_class.new(id: "1", type: "User"))
    expect(described_class.new(id: 1).hash).to eq(described_class.new(id: 1).hash)
  end
end
