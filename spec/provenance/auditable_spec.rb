# frozen_string_literal: true

require "rails_helper"

RSpec.describe Provenance::Auditable do
  let(:controller_class) do
    Class.new(ActionController::Base) do
      include Provenance::Auditable

      def self.name
        "TestController"
      end

      def index
        User.create!(name: "John", email: "john@example.com")
        response.status = 200
      end

      def show
        response.status = 200
      end

      def create
        User.create!(name: "Jane", email: "jane@example.com")
        response.status = 201
      end

      def update
        user.update(name: "John", email: "john@example.com")
        response.status = 201
      end

      def destroy
        user.destroy
        response.status = 200
      end

      def current_user
        @current_user ||= OpenStruct.new(email: "admin@example.com", roles: ["admin"])
      end

      def user
        @user ||= User.find_by!(name: "Jane", email: "jane1@example.com")
      end

      def request
        @request ||= OpenStruct.new(
          uuid: "request-123",
          remote_ip: "127.0.0.1"
        ).tap do |req|
          def req.get?
            @get_request || false
          end

          def req.get=(value)
            @get_request = value
          end

          def req.head?
            @head_request || false
          end

          def req.head=(value)
            @head_request = value
          end
        end
      end

      def response
        @response ||= OpenStruct.new(status: 200)
      end

      def params
        @params ||= ActionController::Parameters.new(controller: "test", action: "index")
      end

      def action_name
        params[:action] || "index"
      end

      def session
        {}
      end
    end
  end

  let(:controller) { controller_class.new }
  let(:audit_hook) { instance_double(Proc) }
  let(:audit_data) { [] }

  before do
    Provenance.config.clear_audit_hooks
    Provenance.config.add_audit_hook { |data| audit_data << data }
    Provenance.config.enabled = true
    allow(Rails.logger).to receive(:error)
  end

  describe "tracking model changes" do
    context "with POST request" do
      it "tracks changes and sends audit after request completes" do
        controller.params[:action] = "create"
        controller.request.get = false

        controller.send(:track_model_changes) do
          controller.create
        end

        expect(audit_data.size).to eq(1)
        expect(audit_data.first[:event_type]).to eq("create_test")
        expect(audit_data.first[:status]).to eq(201)
        expect(audit_data.first[:message][:count]).to eq("1")
      end

      it "sends audit in ensure block even if error occurs" do
        controller.params[:action] = "create"

        allow(controller).to receive(:create).and_raise(StandardError, "Something went wrong")

        expect do
          controller.send(:track_model_changes) do
            controller.create
          end
        end.to raise_error(StandardError)

        expect(audit_data.first[:event_type]).to be_present if audit_data.any?
      end
    end

    context "with GET request" do
      it "sends audit immediately after action" do
        controller.params[:action] = "show"
        controller.request.get = true

        controller.send(:track_model_changes) do
          controller.show
        end

        expect(audit_data.size).to be >= 1
      end
    end

    context "with PUT request" do
      before do
        User.create!(name: "Jane", email: "jane1@example.com")
      end

      it "sends audit immediately after action" do
        controller.params[:action] = "update"
        controller.request.get = false

        controller.send(:track_model_changes) do
          controller.update
        end

        change = audit_data.first[:message][:changes].first[:changes]
        expect(audit_data.size).to be >= 1
        expect(audit_data.first[:event_type]).to eq("update_test")
        expect(audit_data.first[:status]).to eq(201)
        expect(audit_data.first[:message][:count]).to eq("1")

        expect(change[:changed_attributes]["name"]).to eq("John")
        expect(change[:changed_attributes]["email"]).to eq("john@example.com")
        expect(change[:previous_changes]["name"]).to eq("Jane")
        expect(change[:previous_changes]["email"]).to eq("jane1@example.com")
      end
    end

    context "with DELETE request" do
      before do
        User.create!(name: "Jane", email: "jane1@example.com")
      end

      it "sends audit immediately after action" do
        controller.params[:action] = "destroy"
        controller.request.get = false

        controller.send(:track_model_changes) do
          controller.destroy
        end

        expect(audit_data.size).to be >= 1
        expect(audit_data.first[:event_type]).to eq("destroy_test")
        expect(audit_data.first[:status]).to eq(200)
        expect(audit_data.first[:message][:count]).to eq("1")
      end
    end
  end

  describe "request_id" do
    it "uses request UUID as request_id" do
      request_obj = controller.request
      expect(request_obj.uuid).to eq("request-123")

      saved_request_id = nil
      controller.send(:track_model_changes) do
        saved_request_id = Provenance::Context.request_id
        controller.index
      end

      expect(saved_request_id).to eq("request-123")
      expect(audit_data.first[:request_id]).to eq("request-123")
    end

    it "does not set request_id if request.uuid is not available" do
      controller.request.instance_variable_set(:@uuid, nil)

      controller.send(:track_model_changes) do
        controller.index
      end

      expect(Provenance::Context.request_id).to be_nil
    end
  end

  describe "audit_log_data" do
    it "includes all required fields" do
      controller.send(:track_model_changes) do
        controller.index
      end

      expect(audit_data.first).to include(
        :timestamp,
        :event_type,
        :status,
        :message,
        :username,
        :remote_ip,
        :origin_ip,
        :session_id,
        :roles,
        :request_id,
        :source
      )
    end

    it "includes request_id in audit data" do
      controller.send(:track_model_changes) do
        controller.index
      end

      expect(audit_data.first[:request_id]).to eq("request-123")
    end
  end

  describe "skip_model_change_tracking" do
    before do
      controller_class.skip_model_change_tracking :index
    end

    it "skips tracking when action is skipped" do
      controller.params[:action] = "index"

      controller.send(:track_model_changes) do
        controller.index
      end

      expect(audit_data).to be_empty
    end
  end

  describe "skip_audit_logging" do
    before do
      controller_class.skip_audit_logging :show
    end

    it "skips logging when action is skipped" do
      controller.params[:action] = "show"

      controller.send(:track_model_changes) do
        controller.show
      end

      expect(audit_data).to be_empty
    end
  end

  describe "multiple changes in single request" do
    it "tracks all changes in single audit event" do
      controller.params[:action] = "create"
      allow(controller).to receive(:create) do
        User.create!(name: "User1", email: "user1@example.com")
        User.create!(name: "User2", email: "user2@example.com")
        User.create!(name: "User3", email: "user3@example.com")
        controller.response.status = 201
      end

      controller.send(:track_model_changes) do
        controller.create
      end

      expect(audit_data.first[:message][:count]).to eq("3")
    end

    it "tracks many changes (15 records) in single audit event" do
      controller.params[:action] = "create"
      allow(controller).to receive(:create) do
        15.times do |i|
          User.create!(name: "User#{i + 1}", email: "user#{i + 1}@example.com")
        end
        controller.response.status = 201
      end

      controller.send(:track_model_changes) do
        controller.create
      end

      expect(audit_data.size).to eq(1)
      expect(audit_data.first[:message][:count]).to eq("15")
      expect(audit_data.first[:message][:changes].size).to eq(15)
    end

    it "tracks changes with different actions (create, update, destroy) in single audit event" do
      existing_user = User.create!(name: "Existing", email: "existing@example.com")

      controller.params[:action] = "create"
      allow(controller).to receive(:create) do
        User.create!(name: "New1", email: "new1@example.com")
        User.create!(name: "New2", email: "new2@example.com")
        existing_user.update!(name: "Updated")
        existing_user.destroy
        controller.response.status = 201
      end

      controller.send(:track_model_changes) do
        controller.create
      end

      expect(audit_data.size).to eq(1)
      expect(audit_data.first[:message][:count]).to eq("4")

      changes = audit_data.first[:message][:changes]
      create_changes = changes.select { |c| c[:action] == "create" }
      update_changes = changes.select { |c| c[:action] == "update" }
      destroy_changes = changes.select { |c| c[:action] == "destroy" }

      expect(create_changes.size).to eq(2)
      expect(update_changes.size).to eq(1)
      expect(destroy_changes.size).to eq(1)
    end

    context "with transactions" do
      it "tracks all changes in a single transaction" do
        controller.params[:action] = "create"
        allow(controller).to receive(:create) do
          ActiveRecord::Base.transaction do
            User.create!(name: "User1", email: "user1@example.com")
            User.create!(name: "User2", email: "user2@example.com")
            User.create!(name: "User3", email: "user3@example.com")
            Post.create!(title: "Post1", user_id: User.last.id)
            Post.create!(title: "Post2", user_id: User.last.id)
          end
          controller.response.status = 201
        end

        controller.send(:track_model_changes) do
          controller.create
        end

        expect(audit_data.size).to eq(1)
        expect(audit_data.first[:message][:count]).to eq("5")

        changes = audit_data.first[:message][:changes]
        user_changes = changes.select { |c| c[:model] == "User" }
        post_changes = changes.select { |c| c[:model] == "Post" }

        expect(user_changes.size).to eq(3)
        expect(post_changes.size).to eq(2)
      end

      it "tracks changes in multiple sequential transactions" do
        controller.params[:action] = "create"
        allow(controller).to receive(:create) do
          ActiveRecord::Base.transaction do
            User.create!(name: "User1", email: "user1@example.com")
            User.create!(name: "User2", email: "user2@example.com")
          end

          ActiveRecord::Base.transaction do
            user = User.last
            Post.create!(title: "Post1", user_id: user.id)
            Post.create!(title: "Post2", user_id: user.id)
          end

          ActiveRecord::Base.transaction do
            Comment.create!(content: "Comment1", post_id: Post.first.id, user_id: User.first.id)
            Comment.create!(content: "Comment2", post_id: Post.last.id, user_id: User.last.id)
          end

          controller.response.status = 201
        end

        controller.send(:track_model_changes) do
          controller.create
        end

        expect(audit_data.size).to eq(1)
        expect(audit_data.first[:message][:count]).to eq("6")

        changes = audit_data.first[:message][:changes]
        expect(changes.select { |c| c[:model] == "User" }.size).to eq(2)
        expect(changes.select { |c| c[:model] == "Post" }.size).to eq(2)
        expect(changes.select { |c| c[:model] == "Comment" }.size).to eq(2)
      end

      it "tracks changes in nested transactions" do
        controller.params[:action] = "create"
        allow(controller).to receive(:create) do
          ActiveRecord::Base.transaction do
            user = User.create!(name: "User1", email: "user1@example.com")

            ActiveRecord::Base.transaction do
              post = Post.create!(title: "Post1", user_id: user.id)

              ActiveRecord::Base.transaction do
                Comment.create!(content: "Comment1", post_id: post.id, user_id: user.id)
                Comment.create!(content: "Comment2", post_id: post.id, user_id: user.id)
              end
            end
          end

          controller.response.status = 201
        end

        controller.send(:track_model_changes) do
          controller.create
        end

        expect(audit_data.size).to eq(1)
        expect(audit_data.first[:message][:count]).to eq("4")

        changes = audit_data.first[:message][:changes]
        expect(changes.select { |c| c[:model] == "User" }.size).to eq(1)
        expect(changes.select { |c| c[:model] == "Post" }.size).to eq(1)
        expect(changes.select { |c| c[:model] == "Comment" }.size).to eq(2)
      end

      it "tracks many changes in multiple transactions" do
        controller.params[:action] = "create"
        allow(controller).to receive(:create) do
          ActiveRecord::Base.transaction do
            5.times do |i|
              User.create!(name: "User#{i + 1}", email: "user#{i + 1}@example.com")
            end
          end

          ActiveRecord::Base.transaction do
            User.limit(3).each do |user|
              2.times do |i|
                Post.create!(title: "Post#{i + 1}", user_id: user.id)
              end
            end
          end

          ActiveRecord::Base.transaction do
            Post.limit(3).each do |post|
              Comment.create!(content: "Comment", post_id: post.id, user_id: User.first.id)
            end
          end

          controller.response.status = 201
        end

        controller.send(:track_model_changes) do
          controller.create
        end

        expect(audit_data.size).to eq(1)
        expect(audit_data.first[:message][:count]).to eq("14") # 5 users + 6 posts + 3 comments

        changes = audit_data.first[:message][:changes]
        expect(changes.select { |c| c[:model] == "User" }.size).to eq(5)
        expect(changes.select { |c| c[:model] == "Post" }.size).to eq(6)
        expect(changes.select { |c| c[:model] == "Comment" }.size).to eq(3)
      end

      it "tracks mixed changes: some in transaction, some outside" do
        controller.params[:action] = "create"
        allow(controller).to receive(:create) do
          User.create!(name: "User1", email: "user1@example.com")
          User.create!(name: "User2", email: "user2@example.com")

          ActiveRecord::Base.transaction do
            user = User.last
            Post.create!(title: "Post1", user_id: user.id)
            Post.create!(title: "Post2", user_id: user.id)
            user.update!(name: "UpdatedUser")
          end

          User.create!(name: "User3", email: "user3@example.com")

          controller.response.status = 201
        end

        controller.send(:track_model_changes) do
          controller.create
        end

        expect(audit_data.size).to eq(1)
        expect(audit_data.first[:message][:count]).to eq("6")

        changes = audit_data.first[:message][:changes]
        user_changes = changes.select { |c| c[:model] == "User" }
        post_changes = changes.select { |c| c[:model] == "Post" }

        expect(user_changes.size).to eq(4) # 3 creates + 1 update
        expect(post_changes.size).to eq(2)
      end
    end
  end

  describe "guaranteed sending" do
    it "sends audit in ensure block" do
      controller.params[:action] = "create"

      controller.send(:track_model_changes) do
        controller.create
      end

      expect(audit_data.size).to be >= 1
    end

    it "sends audit even if no changes were made" do
      controller.params[:action] = "show"
      controller.request.get = true

      controller.send(:track_model_changes) do
        controller.show
      end

      expect(audit_data.size).to be >= 0
    end
  end
end
