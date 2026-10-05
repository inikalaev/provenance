# frozen_string_literal: true

RSpec.describe "has_provenance" do
  def changes
    events.flat_map { |e| e["changes"] }
  end

  describe "record callbacks" do
    it "records create with after values only" do
      invoice = Invoice.create!(number: "1", amount: "10.50")
      change = changes.sole
      expect(change).to include("entity" => "Invoice", "entity_id" => invoice.id.to_s, "operation" => "create")
      expect(change["diff"]).to eq("number" => "1", "status" => "draft", "amount" => "10.5")
    end

    it "records update with before and after values" do
      invoice = Invoice.create!(number: "1")
      invoice.update!(status: "sent")
      expect(changes.last).to include("operation" => "update", "diff" => {"status" => %w[draft sent]})
    end

    it "skips updates that only touch ignored attributes" do
      invoice = Invoice.create!(number: "1")
      invoice.touch
      invoice.update!(updated_at: 1.day.from_now)
      expect(changes.size).to eq(1)
    end

    it "records destroy with before values only" do
      invoice = Invoice.create!(number: "1")
      invoice.destroy!
      expect(changes.last).to include("operation" => "destroy", "diff" => {"number" => "1", "status" => "draft"})
    end

    it "honours only:" do
      Account.create!(name: "a", balance: 5)
      expect(changes.sole["diff"]).to eq("name" => "a", "balance" => 5)
    end

    it "honours except:" do
      Document.create!(title: "t", body: "b")
      expect(changes.sole["diff"]).to eq("title" => "t")
    end

    it "redacts model, configured and Rails filter_parameters attributes" do
      Provenance.config.redact_attributes += %i[iban]
      invoice = Invoice.create!(number: "1", notes: "private", iban: "DE00", password_hint: "pet")
      invoice.update!(notes: "still private", iban: "DE01", password_hint: "cat")

      expect(changes.first["diff"]).to include("notes" => "[REDACTED]", "iban" => "[REDACTED]", "password_hint" => "[REDACTED]")
      expect(changes.last["diff"]).to eq(
        "notes" => ["[REDACTED]", "[REDACTED]"], "iban" => ["[REDACTED]", "[REDACTED]"],
        "password_hint" => ["[REDACTED]", "[REDACTED]"]
      )
    end

    it "keeps nil on a redacted side so the change stays visible" do
      invoice = Invoice.create!(number: "1")
      invoice.update!(notes: "secret")
      expect(changes.last["diff"]).to eq("notes" => [nil, "[REDACTED]"])
    end

    it "redacts by partial filter_parameters match" do
      Account.create!(name: "a", secret_code: "1234")
      expect(changes.sole["diff"]["secret_code"]).to eq("[REDACTED]")
    end

    it "redacts encrypted attributes" do
      Vault.create!(name: "v", pin: "1234")
      expect(changes.sole["diff"]).to eq("name" => "v", "pin" => "[REDACTED]")
    end

    it "skips records matching ignore_if" do
      Invoice.create!(number: "IGNORED")
      expect(events).to be_empty
    end

    it "converts values to JSON-safe forms" do
      time = Time.utc(2026, 10, 5, 12, 0, 0.123r)
      Invoice.create!(number: "1", amount: "1234.5", paid_at: time, attachment: "\x00\xFF\x01".b)
      diff = changes.sole["diff"]
      expect(diff["amount"]).to eq("1234.5")
      expect(diff["paid_at"]).to eq("2026-10-05T12:00:00.123Z")
      expect(diff["attachment"]).to eq("[BINARY 3 bytes]")
    end

    it "does not track models without has_provenance" do
      Note.create!(body: "x")
      expect(events).to be_empty
    end

    it "tracks STI subclasses with the parent options" do
      memo = Memo.create!(title: "m", body: "hidden")
      expect(changes.sole).to include("entity" => "Memo", "entity_id" => memo.id.to_s)
      expect(changes.sole["diff"]).not_to have_key("body")
    end

    it "rejects only: together with except:" do
      expect { Class.new(ActiveRecord::Base) { has_provenance only: [:a], except: [:b] } }.to raise_error(ArgumentError)
    end

    it "rejects unknown associations" do
      klass = Class.new(ActiveRecord::Base) do
        self.table_name = "notes"
        def self.name = "TmpNote"
      end
      expect { klass.has_provenance(associations: [:missing]) }.to raise_error(ArgumentError, /missing/)
    end
  end

  describe "transactions" do
    it "emits after commit" do
      Provenance.action("tx") do
        ActiveRecord::Base.transaction do
          Invoice.create!(number: "1")
          expect(events).to be_empty
        end
      end
      expect(changes.size).to eq(1)
    end

    it "drops changes of rolled-back transactions" do
      Provenance.action("tx") do
        Invoice.create!(number: "kept")
        ActiveRecord::Base.transaction do
          Invoice.create!(number: "dropped")
          raise ActiveRecord::Rollback
        end
      end
      expect(changes.map { |c| c["diff"]["number"] }).to eq(["kept"])
    end

    it "drops changes of rolled-back savepoints only" do
      Provenance.action("tx") do
        ActiveRecord::Base.transaction do
          Invoice.create!(number: "outer")
          ActiveRecord::Base.transaction(requires_new: true) do
            Invoice.create!(number: "savepoint")
            raise ActiveRecord::Rollback
          end
        end
      end
      expect(changes.map { |c| c["diff"]["number"] }).to eq(["outer"])
    end

    it "defers emission of an action closed inside a transaction until commit" do
      ActiveRecord::Base.transaction do
        Provenance.action("inside") { Invoice.create!(number: "1") }
        expect(events).to be_empty
      end
      expect(events.size).to eq(1)
    end

    it "emits nothing for implicit actions whose transaction rolls back" do
      ActiveRecord::Base.transaction do
        Invoice.create!(number: "1")
        raise ActiveRecord::Rollback
      end
      expect(events).to be_empty
    end
  end

  describe "associations" do
    it "records link and unlink" do
      invoice = Invoice.create!(number: "1")
      tag = Tag.create!(name: "urgent")
      Provenance.action("tagging") do
        invoice.tags << tag
        invoice.tags.delete(tag)
      end

      link, unlink = events.last["changes"]
      expect(link).to include("entity" => "Invoice", "entity_id" => invoice.id.to_s, "operation" => "link",
        "association" => "tags", "target" => {"type" => "Tag", "id" => tag.id.to_s})
      expect(unlink).to include("operation" => "unlink", "association" => "tags")
      expect(schema_errors(events.last)).to be_empty
    end

    it "resolves ids of records saved together with the owner" do
      Provenance.action("new") do
        invoice = Invoice.new(number: "1")
        invoice.tags << Tag.new(name: "fresh")
        invoice.save!
      end

      link = events.sole["changes"].find { |c| c["operation"] == "link" }
      expect(link["entity_id"]).to eq(Invoice.last.id.to_s)
      expect(link["target"]["id"]).to eq(Tag.last.id.to_s)
    end
  end

  describe "bulk operations" do
    before { 3.times { |i| Invoice.create!(number: i.to_s) } }

    let(:bulk) { events.last["changes"].sole }

    it "records update_all with count, fingerprint and ids" do
      ids = Invoice.order(:id).pluck(:id).map(&:to_s)
      Invoice.where(status: "draft").update_all(status: "void")

      expect(bulk).to include("entity" => "Invoice", "operation" => "bulk_update", "count" => 3,
        "ids" => ids, "truncated" => false, "diff" => {"status" => [nil, "void"]})
      expect(bulk["where"]).to match(/\Asha256:\h{16}\z/)
      expect(schema_errors(events.last)).to be_empty
    end

    it "produces the same fingerprint for the same query shape" do
      Invoice.where(number: "0").update_all(notes: "x")
      Invoice.where(number: "1").update_all(notes: "y")
      first, second = events.last(2).map { |e| e["changes"].sole }
      expect(first["where"]).to eq(second["where"])
      expect(first["diff"]).to eq("notes" => [nil, "[REDACTED]"])
    end

    it "records delete_all" do
      Invoice.where(number: %w[0 1]).delete_all
      expect(bulk).to include("operation" => "bulk_delete", "count" => 2, "diff" => nil)
      expect(bulk["ids"].size).to eq(2)
    end

    it "truncates ids at bulk_ids_limit" do
      Provenance.config.bulk_ids_limit = 2
      Invoice.update_all(status: "x")
      expect(bulk).to include("count" => 3, "truncated" => true)
      expect(bulk["ids"].size).to eq(2)
    end

    it "fetches ids with a single pluck before the write" do
      queries = []
      callback = ->(*, payload) { queries << payload[:sql] unless payload[:name] == "SCHEMA" }
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        Invoice.where(status: "draft").update_all(status: "x")
      end
      expect(queries.size).to eq(2)
      expect(queries.first).to match(/\ASELECT/)
      expect(queries.last).to match(/\AUPDATE/)
    end

    it "uses loaded records instead of plucking" do
      relation = Invoice.where(status: "draft").load
      queries = []
      callback = ->(*, payload) { queries << payload[:sql] }
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { relation.update_all(status: "x") }
      expect(queries.size).to eq(1)
      expect(bulk["ids"].size).to eq(3)
    end

    it "records insert_all and upsert_all" do
      now = Time.current
      Invoice.insert_all([{number: "9", created_at: now, updated_at: now}, {number: "10", created_at: now, updated_at: now}])
      expect(bulk).to include("operation" => "bulk_insert", "count" => 2)

      Account.upsert_all([{id: 100, name: "x"}])
      expect(events.last["changes"].sole).to include("operation" => "bulk_insert", "count" => 1, "ids" => ["100"])
    end

    it "records bulk changes through association relations" do
      invoice = Invoice.first
      invoice.tags << Tag.create!(name: "a")
      Tag.update_all(name: "b")
      expect(events.last["changes"].sole["operation"]).to eq("link")

      Invoice.where(id: invoice.id).limit(1).update_all(status: "limited")
      expect(bulk).to include("count" => 1, "ids" => [invoice.id.to_s])
    end

    it "drops bulk changes on rollback" do
      count = events.size
      ActiveRecord::Base.transaction do
        Invoice.update_all(status: "x")
        raise ActiveRecord::Rollback
      end
      expect(events.size).to eq(count)
    end

    it "does not track bulk operations on untracked models" do
      Note.create!(body: "a")
      count = events.size
      Note.update_all(body: "b")
      Note.delete_all
      expect(events.size).to eq(count)
    end

    it "tracks bulk operations on STI subclasses" do
      Memo.create!(title: "a")
      Memo.update_all(title: "b")
      expect(bulk).to include("entity" => "Memo", "operation" => "bulk_update")
    end
  end
end
