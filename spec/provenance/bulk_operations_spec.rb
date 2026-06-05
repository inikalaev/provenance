# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Provenance bulk operations tracking", type: :integration do
  before do
    Provenance.config.enabled = true
    Provenance.config.track_bulk_operations = true
    Provenance::Context.journal = Provenance::Journal.new
    Provenance::Context.request_id = "bulk-test-123"
  end

  after do
    Provenance.config.track_bulk_operations = false
    Provenance::Context.cleanup
  end

  let(:journal) { Provenance::Context.journal }

  def setup_comments
    user = User.create!(name: "John", email: "john@example.com")
    post = Post.create!(title: "Test", body: "Content", user: user)
    c1 = Comment.create!(content: "a", post: post, user: user, status: "published")
    c2 = Comment.create!(content: "b", post: post, user: user, status: "published")
    journal.clear!
    [post, c1, c2]
  end

  it "tracks update_all with affected ids and changed attributes" do
    post, c1, c2 = setup_comments

    travel_to Time.utc(2026, 6, 5, 12) do
      ActiveRecord::Base.transaction do
        Comment.where(post_id: post.id, status: "published")
          .update_all(status: "deleted", deleted_at: Time.current)
      end
    end

    bulk = journal.changes.find { |c| c[:action] == "bulk_update" }
    expect(bulk).not_to be_nil
    expect(bulk[:model]).to eq("Comment")
    expect(bulk[:model_ids]).to contain_exactly(c1.id, c2.id)
    expect(bulk[:count]).to eq(2)
    expect(bulk[:changes][:status]).to eq("deleted")
    expect(bulk[:changes]).to have_key(:deleted_at)
  end

  it "tracks delete_all with affected ids" do
    post, c1, c2 = setup_comments

    ActiveRecord::Base.transaction do
      Comment.where(post_id: post.id).delete_all
    end

    bulk = journal.changes.find { |c| c[:action] == "bulk_delete" }
    expect(bulk).not_to be_nil
    expect(bulk[:model]).to eq("Comment")
    expect(bulk[:model_ids]).to contain_exactly(c1.id, c2.id)
  end

  it "does not track when track_bulk_operations is disabled" do
    Provenance.config.track_bulk_operations = false
    post, = setup_comments

    Comment.where(post_id: post.id).update_all(status: "deleted")

    expect(journal.changes.any? { |c| c[:action] == "bulk_update" }).to be(false)
  end

  it "does not track when there is no active journal (outside request)" do
    post, = setup_comments
    Provenance::Context.journal = nil

    expect do
      Comment.where(post_id: post.id).update_all(status: "deleted")
    end.not_to raise_error
  end

  it "removes bulk change on transaction rollback" do
    post, = setup_comments

    begin
      ActiveRecord::Base.transaction do
        Comment.where(post_id: post.id).update_all(status: "deleted", deleted_at: Time.current)
        # A record from the same transaction so the after_rollback callback fires.
        Post.create!(title: "x", body: "y", user_id: post.user_id)
        raise ActiveRecord::Rollback
      end
    rescue ActiveRecord::Rollback
      nil
    end

    expect(journal.changes.any? { |c| c[:action] == "bulk_update" }).to be(false)
  end

  it "delivers bulk change in the audit log through the controller flow" do
    audit_data = []
    Provenance.config.clear_audit_hooks
    Provenance.config.add_audit_hook { |data| audit_data << data }

    controller_class = Class.new(ActionController::Base) do
      include Provenance::Auditable

      def self.name = "CommentsController"

      def tree
        post_id = params[:post_id]
        ActiveRecord::Base.transaction do
          Comment.where(post_id: post_id, status: "published")
            .update_all(status: "deleted", deleted_at: Time.current)
        end
        response.status = 204
      end

      def request
        @request ||= OpenStruct.new(uuid: "req-1", remote_ip: "127.0.0.1").tap do |r|
          def r.get? = false
          def r.head? = false
        end
      end

      def response = @response ||= OpenStruct.new(status: 200)
      def params = @params ||= ActionController::Parameters.new(controller: "comments", action: "tree")
      def action_name = params[:action]
      def session = {}
    end

    post, c1, c2 = setup_comments
    controller = controller_class.new
    controller.params[:post_id] = post.id
    controller.params[:id] = c1.post_id

    controller.send(:track_model_changes) { controller.tree }

    expect(audit_data.size).to eq(1)
    bulk = audit_data.first[:message][:changes].find { |c| c[:action] == "bulk_update" }
    expect(bulk).not_to be_nil
    expect(bulk[:model_ids]).to contain_exactly(c1.id.to_s, c2.id.to_s)
    expect(bulk[:changes][:status]).to eq("deleted")
  end

  it "delivers bulk change together with an AR create committed in the same transaction" do
    audit_data = []
    Provenance.config.clear_audit_hooks
    Provenance.config.add_audit_hook { |data| audit_data << data }

    controller_class = Class.new(ActionController::Base) do
      include Provenance::Auditable

      def self.name = "CommentsController"

      def tree
        post_id = params[:post_id]
        user_id = params[:user_id]
        ActiveRecord::Base.transaction do
          Comment.where(post_id: post_id, status: "published")
            .update_all(status: "deleted", deleted_at: Time.current)
          # An AR create in the same transaction closes it and triggers delivery.
          Post.create!(title: "event", body: "deleted", user_id: user_id)
        end
        response.status = 204
      end

      def request
        @request ||= OpenStruct.new(uuid: "req-1", remote_ip: "127.0.0.1").tap do |r|
          def r.get? = false
          def r.head? = false
        end
      end

      def response = @response ||= OpenStruct.new(status: 200)
      def params = @params ||= ActionController::Parameters.new(controller: "comments", action: "tree")
      def action_name = params[:action]
      def session = {}
    end

    post, c1, c2 = setup_comments
    controller = controller_class.new
    controller.params[:post_id] = post.id
    controller.params[:user_id] = post.user_id

    controller.send(:track_model_changes) { controller.tree }

    expect(audit_data.size).to eq(1)
    changes = audit_data.first[:message][:changes]
    bulk = changes.find { |c| c[:action] == "bulk_update" }
    create = changes.find { |c| c[:action] == "create" && c[:model] == "Post" }
    expect(bulk).not_to be_nil
    expect(bulk[:model_ids]).to contain_exactly(c1.id.to_s, c2.id.to_s)
    expect(create).not_to be_nil
  end

  it "never breaks the underlying operation if tracking fails" do
    post, = setup_comments
    allow(journal).to receive(:add_bulk_change).and_raise(StandardError, "boom")

    expect do
      Comment.where(post_id: post.id).update_all(status: "deleted")
    end.not_to raise_error

    expect(Comment.where(post_id: post.id, status: "deleted").count).to eq(2)
  end
end
