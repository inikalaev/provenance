# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Provenance integration", type: :integration do
  let(:audit_data) { [] }

  before do
    Provenance.config.clear_audit_hooks
    Provenance.config.add_audit_hook { |data| audit_data << data }
    Provenance.config.enabled = true
    Provenance::Context.journal = Provenance::Journal.new
    Provenance::Context.request_id = "integration-test-123"
  end

  after do
    Provenance::Context.cleanup
  end

  describe "acts_as_list integration" do
    it "tracks position changes from acts_as_list callbacks" do
      user = User.create!(name: "John", email: "john@example.com")
      post = Post.create!(title: "Test", body: "Content", user: user)
      Comment.create!(content: "First", post: post, user: user)
      Comment.create!(content: "Second", post: post, user: user)
      comment3 = Comment.create!(content: "Third", post: post, user: user)

      journal = Provenance::Context.journal
      journal.clear!

      ActiveRecord::Base.transaction do
        comment3.move_to_top
      end

      journal = Provenance::Context.journal
      update_changes = journal.changes.select { |c| c[:action] == "update" && c[:model_id] == comment3.id }.last
      expect(update_changes[:changes][:changed_attributes]["position"]).to eq 1
    end

    it "tracks changes when item is inserted at specific position" do
      user = User.create!(name: "John", email: "john@example.com")
      post = Post.create!(title: "Test", body: "Content", user: user)

      ActiveRecord::Base.transaction do
        3.times do |i|
          Comment.create!(content: "Comment #{i}", post: post, user: user)
        end
      end

      journal = Provenance::Context.journal
      initial_count = journal.changes.size

      ActiveRecord::Base.transaction do
        new_comment = Comment.new(content: "New Comment", post: post, user: user)
        new_comment.insert_at(2)
      end

      expect(journal.changes.size).to be > initial_count
      new_comment_changes = journal.changes.last
      expect(new_comment_changes[:changes][:attributes]["position"]).to eq 2
    end

    it "handles transaction rollback with acts_as_list operations" do
      user = User.create!(name: "John", email: "john@example.com")
      post = Post.create!(title: "Test", body: "Content", user: user)
      comments = [
        Comment.create!(content: "First", post: post, user: user),
        Comment.create!(content: "Second", post: post, user: user)
      ]

      journal = Provenance::Context.journal
      initial_count = journal.changes.size

      begin
        ActiveRecord::Base.transaction do
          comments.first.move_to_top
          raise ActiveRecord::Rollback
        end
      rescue ActiveRecord::Rollback
        nil
      end

      expect(journal.changes.size).to eq(initial_count)
    end

    it "tracks multiple position updates when moving item" do
      user = User.create!(name: "John", email: "john@example.com")
      post = Post.create!(title: "Test", body: "Content", user: user)

      comments = []
      ActiveRecord::Base.transaction do
        5.times do |i|
          comments << Comment.create!(content: "Comment #{i}", post: post, user: user)
        end
      end

      journal = Provenance::Context.journal
      initial_count = journal.changes.size

      ActiveRecord::Base.transaction do
        comments.last.move_to_top
      end

      journal = Provenance::Context.journal
      expect(journal.changes.size).to be > initial_count

      update_changes = journal.changes.select { |c| c[:action] == "update" && c[:model] == "Comment" }
      expect(update_changes.size).to be >= 1
    end
  end
end
