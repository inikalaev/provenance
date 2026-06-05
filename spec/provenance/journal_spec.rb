# frozen_string_literal: true

require "rails_helper"

RSpec.describe Provenance::Journal do
  let(:journal) { described_class.new }
  let(:user) { User.create!(name: "John", email: "john@example.com", password: "secret") }

  before do
    Provenance.config.sensitive_attributes = %w[password api_key]
  end

  describe "#initialize" do
    it "creates empty changes array" do
      expect(journal.changes).to be_empty
    end
  end

  describe "#add_change" do
    context "with create action" do
      it "adds change to journal" do
        journal.add_change(user, :create, { attributes: { name: "John" } })

        expect(journal.changes.size).to eq(1)
        expect(journal.changes.first[:model]).to eq("User")
        expect(journal.changes.first[:action]).to eq("create")
        expect(journal.changes.first[:model_id]).to eq(user.id)
      end

      it "filters sensitive attributes" do
        journal.add_change(user, :create, { attributes: { name: "John", password: "secret123" } })

        change = journal.changes.first
        expect(change[:changes][:attributes][:password]).to eq("[FILTERED]")
        expect(change[:changes][:attributes][:name]).to eq("John")
      end

      it "includes transaction_id if provided" do
        journal.add_change(user, :create, { attributes: {}, transaction_id: "tx123" })

        expect(journal.changes.first[:transaction_id]).to eq("tx123")
      end

      it "adds timestamp" do
        freeze_time do
          journal.add_change(user, :create, { attributes: {} })
          timestamp = journal.changes.first[:timestamp]

          expect(timestamp).to eq(Time.current.utc.iso8601(3))
        end
      end
    end

    context "with update action" do
      it "adds change with changed attributes" do
        user.update!(name: "Jane")
        journal.add_change(user, :update, {
          changed_attributes: { name: "Jane" },
          previous_changes: { name: %w[John Jane] }
        })

        expect(journal.changes.first[:action]).to eq("update")
        expect(journal.changes.first[:changes][:changed_attributes][:name]).to eq("Jane")
      end
    end

    context "with destroy action" do
      it "adds change with attributes" do
        journal.add_change(user, :destroy, { attributes: { name: "John" } })

        expect(journal.changes.first[:action]).to eq("destroy")
      end
    end
  end

  describe "#remove_changes_for_transaction" do
    it "removes changes for specific transaction" do
      journal.add_change(user, :create, { attributes: {}, transaction_id: "tx1" })
      journal.add_change(user, :create, { attributes: {}, transaction_id: "tx2" })
      journal.add_change(user, :create, { attributes: {}, transaction_id: "tx1" })

      journal.remove_changes_for_transaction("tx1")

      expect(journal.changes.size).to eq(1)
      expect(journal.changes.first[:transaction_id]).to eq("tx2")
    end

    it "does nothing if transaction_id is nil" do
      journal.add_change(user, :create, { attributes: {} })
      initial_size = journal.changes.size

      journal.remove_changes_for_transaction(nil)

      expect(journal.changes.size).to eq(initial_size)
    end

    it "does nothing if no changes match" do
      journal.add_change(user, :create, { attributes: {}, transaction_id: "tx1" })

      journal.remove_changes_for_transaction("tx999")

      expect(journal.changes.size).to eq(1)
    end
  end

  describe "#present?" do
    it "returns false when empty" do
      expect(journal.present?).to be false
    end

    it "returns true when has changes" do
      journal.add_change(user, :create, { attributes: {} })
      expect(journal.present?).to be true
    end
  end

  describe "#to_h" do
    it "returns hash with count and changes" do
      journal.add_change(user, :create, { attributes: {} })
      journal.add_change(user, :update, { changed_attributes: {} })

      result = journal.to_h

      expect(result[:count]).to eq(2)
      expect(result[:changes].size).to eq(2)
    end
  end

  describe "transaction_id tracking" do
    it "tracks changes with different transaction_ids" do
      journal.add_change(user, :create, { attributes: {}, transaction_id: "tx1" })
      journal.add_change(user, :create, { attributes: {}, transaction_id: "tx2" })
      journal.add_change(user, :create, { attributes: {}, transaction_id: "tx1" })

      tx1_changes = journal.changes.select { |c| c[:transaction_id] == "tx1" }
      tx2_changes = journal.changes.select { |c| c[:transaction_id] == "tx2" }

      expect(tx1_changes.size).to eq(2)
      expect(tx2_changes.size).to eq(1)
    end

    it "handles changes without transaction_id" do
      journal.add_change(user, :create, { attributes: {} })

      changes_without_tx = journal.changes.select { |c| c[:transaction_id].nil? }
      expect(changes_without_tx.size).to eq(1)
    end
  end

  describe "#clear!" do
    it "clears all changes" do
      journal.add_change(user, :create, { attributes: {} })
      journal.add_change(user, :update, { changed_attributes: {} })

      journal.clear!

      expect(journal.changes).to be_empty
      expect(journal.empty?).to be true
    end
  end

  describe "sensitive attributes filtering" do
    context "with model-specific sensitive attributes" do
      let(:payment) { Post.create!(title: "Payment", body: "Data", user: user) }

      before do
        User.sensitive_attributes :email
      end

      after do
        User.instance_variable_set(:@sensitive_attributes, [])
      end

      it "filters model-specific sensitive attributes" do
        journal.add_change(user, :create, { attributes: { name: "John", email: "john@example.com" } })

        change = journal.changes.first
        expect(change[:changes][:attributes][:email]).to eq("[FILTERED]")
        expect(change[:changes][:attributes][:name]).to eq("John")
      end
    end

    context "with nested hashes" do
      it "filters sensitive attributes in nested structures" do
        journal.add_change(user, :create, {
          attributes: {
            name: "John",
            settings: {
              password: "secret",
              api_key: "key123"
            }
          }
        })

        change = journal.changes.first
        expect(change[:changes][:attributes][:settings][:password]).to eq("[FILTERED]")
      end
    end

    context "with arrays" do
      it "filters sensitive attributes in arrays" do
        journal.add_change(user, :create, {
          attributes: [
            { name: "John", password: "secret1" },
            { name: "Jane", password: "secret2" }
          ]
        })

        change = journal.changes.first
        passwords = change[:changes][:attributes].map { |item| item[:password] }
        expect(passwords).to all(eq("[FILTERED]"))
      end
    end
  end
end
