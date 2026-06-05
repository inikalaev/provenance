# frozen_string_literal: true

require "rails_helper"

RSpec.describe Provenance::Trackable do
  let(:journal) { Provenance::Journal.new }
  let(:audit_hook) { instance_double(Proc) }

  before do
    Provenance.config.sensitive_attributes = [:password]
    Provenance::Context.journal = journal
    Provenance::Context.request_id = "test-request-123"
    Provenance.config.add_audit_hook { |data| audit_hook.call(data) }
    allow(audit_hook).to receive(:call)
  end

  describe "single transaction" do
    context "with create" do
      it "tracks create in transaction" do
        ActiveRecord::Base.transaction do
          User.create!(name: "John", email: "john@example.com", password: "secret")
        end

        expect(journal.changes.size).to eq(1)
        expect(journal.changes.first[:action]).to eq("create")
        expect(journal.changes.first[:model]).to eq("User")
        expect(journal.changes.first[:transaction_id]).to be_present
      end

      it "captures transaction_id before commit" do
        transaction_id = nil

        ActiveRecord::Base.transaction do
          User.create!(name: "John", email: "john@example.com")
          connection = User.connection
          if connection.current_transaction
            transaction_id = "#{Provenance::Context.request_id}:#{connection.current_transaction.object_id}"
          end
        end

        expect(journal.changes.first[:transaction_id]).to eq(transaction_id) if transaction_id
      end
    end

    context "with update" do
      it "tracks update in transaction" do
        user = User.create!(name: "John", email: "john@example.com", password: "secret")
        journal.clear!

        ActiveRecord::Base.transaction do
          user.update!(name: "Jane")
        end

        expect(journal.changes.size).to eq(1)
        expect(journal.changes.first[:action]).to eq("update")
        expect(journal.changes.first[:changes][:changed_attributes]["name"]).to eq("Jane")
      end

      it "tracks multiple updates in same transaction" do
        user = User.create!(name: "John", email: "john@example.com", password: "secret")
        journal.clear!

        ActiveRecord::Base.transaction do
          user.update!(name: "Jane")
          user.update!(email: "jane@example.com")
        end

        expect(journal.changes.size).to eq(2)

        expect(journal.changes.first[:action]).to eq("update")
        expect(journal.changes.last[:changes][:changed_attributes]["email"]).to eq("jane@example.com")
        expect(journal.changes.first[:changes][:changed_attributes]["name"]).to eq("Jane")
      end
    end

    context "with destroy" do
      it "tracks destroy in transaction" do
        user = User.create!(name: "John", email: "john@example.com", password: "secret")
        journal.clear!

        ActiveRecord::Base.transaction do
          user.destroy
        end

        expect(journal.changes.size).to eq(1)
        expect(journal.changes.first[:action]).to eq("destroy")
      end
    end
  end

  describe "multiple independent transactions" do
    it "tracks changes from different transactions separately" do
      transaction_ids = []

      ActiveRecord::Base.transaction do
        User.create!(name: "User1", email: "user1@example.com")
        transaction_ids << journal.changes.last[:transaction_id]
      end

      ActiveRecord::Base.transaction do
        User.create!(name: "User2", email: "user2@example.com")
        transaction_ids << journal.changes.last[:transaction_id]
      end

      expect(journal.changes.size).to eq(2)
      expect(transaction_ids.uniq.size).to eq(2), "Each transaction should have unique ID"
      expect(transaction_ids.first).not_to eq(transaction_ids.last)
    end

    it "groups changes by transaction_id correctly" do
      ActiveRecord::Base.transaction do
        User.create!(name: "User1", email: "user1@example.com")
      end

      ActiveRecord::Base.transaction do
        User.create!(name: "User2", email: "user2@example.com")
        User.create!(name: "User3", email: "user3@example.com")
      end

      transaction_ids = journal.changes.map { |c| c[:transaction_id] }.uniq
      expect(transaction_ids.size).to eq(2)

      first_tx_id = transaction_ids.first
      second_tx_id = transaction_ids.last

      first_tx_changes = journal.changes.select { |c| c[:transaction_id] == first_tx_id }
      second_tx_changes = journal.changes.select { |c| c[:transaction_id] == second_tx_id }

      expect([first_tx_changes.size, second_tx_changes.size].sort).to eq([1, 2])
    end
  end

  describe "transaction rollback" do
    it "removes changes when transaction is rolled back" do
      begin
        ActiveRecord::Base.transaction do
          User.create!(name: "John", email: "john@example.com")
          raise ActiveRecord::Rollback
        end
      rescue ActiveRecord::Rollback
        nil
      end

      expect(journal.changes).to be_empty
    end

    it "removes changes when exception occurs in transaction" do
      expect do
        ActiveRecord::Base.transaction do
          User.create!(name: "John", email: "john@example.com")
          raise StandardError, "Something went wrong"
        end
      end.to raise_error(StandardError)

      expect(journal.changes).to be_empty
    end

    it "keeps changes from previous successful transactions after rollback" do
      ActiveRecord::Base.transaction do
        User.create!(name: "User1", email: "user_test_transactions1@example.com")
      end

      begin
        ActiveRecord::Base.transaction do
          User.create!(name: "User2", email: "user_test_transactions2@example.com")
          raise ActiveRecord::Rollback
        end
      rescue ActiveRecord::Rollback
        nil
      end

      expect(journal.changes.size).to eq(1)
      expect(journal.changes.first[:model_id]).to eq(User.find_by(email: "user_test_transactions1@example.com")&.id)
    end
  end

  describe "operations without transactions (autocommit)" do
    it "tracks changes using request_id when no transaction" do
      User.create!(name: "John", email: "john@example.com")

      expect(journal.changes.size).to eq(1)
      expect(journal.changes.first[:transaction_id]).to match(/^test-request-123/)
    end
  end

  describe "multiple changes in single transaction" do
    it "tracks multiple creates in same transaction" do
      ActiveRecord::Base.transaction do
        5.times do |i|
          User.create!(name: "User#{i}", email: "user#{i}@example.com")
        end
      end

      expect(journal.changes.size).to eq(5)
      expect(journal.changes.all? { |c| c[:action] == "create" }).to be true
      transaction_ids = journal.changes.map { |c| c[:transaction_id] }.uniq
      expect(transaction_ids.size).to eq(1)
    end

    it "tracks mixed operations in same transaction" do
      user1 = nil

      ActiveRecord::Base.transaction do
        user1 = User.create!(name: "User1", email: "user1@example.com")
        User.create!(name: "User2", email: "user2@example.com")
        user1.update!(name: "UpdatedUser1")
      end

      expect(journal.changes.size).to eq(3)
      creates = journal.changes.select { |c| c[:action] == "create" }
      updates = journal.changes.select { |c| c[:action] == "update" }

      expect(creates.size).to eq(2)
      expect(updates.size).to eq(1)
    end
  end

  describe "sensitive attributes" do
    it "filters sensitive attributes on create" do
      ActiveRecord::Base.transaction do
        User.create!(name: "John", email: "john@example.com", password: "secret123")
      end

      change = journal.changes.first
      expect(change[:changes][:attributes]["password"]).to eq("[FILTERED]")
      expect(change[:changes][:attributes]["name"]).to eq("John")
    end

    it "filters sensitive attributes on update" do
      user = User.create!(name: "John", email: "john@example.com", password: "old_secret")
      journal.clear!
      ActiveRecord::Base.transaction do
        user.update!(password: "new_secret")
      end

      change = journal.changes.first
      expect(change[:changes][:changed_attributes]["password"]).to eq("[FILTERED]")
    end
  end

  describe "collects changes" do
    it "collects changes for later sending" do
      expect(Provenance::Context.journal.present?).to be false

      User.create!(name: "John", email: "john@example.com")

      expect(Provenance::Context.journal.present?).to be true
      expect(Provenance::Context.journal.changes.size).to eq(1)
    end
  end
end
