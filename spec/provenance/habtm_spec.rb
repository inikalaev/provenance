# frozen_string_literal: true

require "rails_helper"

# has_and_belongs_to_many writes hit the join table directly and never trigger
# model callbacks, so Trackable observes them through SQL notifications. These
# specs lock in that the changes land in the journal synchronously, which is
# also what makes the removal of the old post-commit scheduling safe.
RSpec.describe "Provenance has_and_belongs_to_many tracking" do
  before do
    Provenance.config.enabled = true
    Provenance::Context.journal = Provenance::Journal.new
    Provenance::Context.request_id = "habtm-test-123"
  end

  after do
    Provenance::Context.cleanup
  end

  let(:journal) { Provenance::Context.journal }

  def tags_change
    journal.changes.find do |change|
      change[:model] == "Post" &&
        change[:action] == "update" &&
        change[:changes][:changed_attributes]&.key?("tags_ids")
    end
  end

  it "records a join-table insert as an update on the owner" do
    user = User.create!(name: "John", email: "habtm1@example.com")
    post = Post.create!(title: "Post", user: user)
    tag = Tag.create!(name: "ruby")
    journal.clear!

    post.tags << tag

    change = tags_change
    expect(change).not_to be_nil
    expect(change[:model_id]).to eq(post.id)
    expect(change[:changes][:changed_attributes]["tags_ids"]).to include(tag.id.to_s)
  end

  it "accumulates multiple tags added in the same request" do
    user = User.create!(name: "John", email: "habtm2@example.com")
    post = Post.create!(title: "Post", user: user)
    ruby = Tag.create!(name: "ruby")
    rails = Tag.create!(name: "rails")
    journal.clear!

    post.tags << ruby
    post.tags << rails

    change = tags_change
    expect(change).not_to be_nil
    expect(change[:changes][:changed_attributes]["tags_ids"]).to include(ruby.id.to_s, rails.id.to_s)
  end

  it "does not track join-table writes when there is no active journal" do
    user = User.create!(name: "John", email: "habtm3@example.com")
    post = Post.create!(title: "Post", user: user)
    tag = Tag.create!(name: "ruby")
    Provenance::Context.journal = nil

    expect { post.tags << tag }.not_to raise_error
  end
end
