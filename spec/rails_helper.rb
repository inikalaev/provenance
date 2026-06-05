# frozen_string_literal: true

require "spec_helper"
ENV["RAILS_ENV"] ||= "test"

require "ostruct"
require "rails/all"
require "active_support/testing/time_helpers"

begin
  require "acts_as_list"
rescue LoadError
  nil
end

require "provenance"
require_relative "support/models"

RSpec.configure do |config|
  config.include ActiveSupport::Testing::TimeHelpers
  config.include ActiveJob::TestHelper

  config.before(:suite) do
    ActiveRecord::Base.establish_connection(
      adapter: "sqlite3",
      database: ":memory:"
    )

    ActiveRecord::Schema.define do
      create_table :users, force: true do |t|
        t.string :name
        t.string :email
        t.string :password
        t.integer :position
        t.timestamps
      end

      create_table :posts, force: true do |t|
        t.string :title
        t.text :body
        t.integer :user_id
        t.integer :position
        t.timestamps
      end

      create_table :comments, force: true do |t|
        t.text :content
        t.integer :post_id
        t.integer :user_id
        t.integer :position
        t.string :status
        t.datetime :deleted_at
        t.timestamps
      end

      create_table :categories, force: true do |t|
        t.string :name
        t.integer :position
        t.timestamps
      end

      create_table :tags, force: true do |t|
        t.string :name
        t.timestamps
      end

      create_table :posts_tags, force: true, id: false do |t|
        t.integer :post_id
        t.integer :tag_id
      end
    end
  end

  config.before(:each) do
    Provenance::Context.cleanup
    Provenance.config.clear_audit_hooks
    Provenance.config.enabled = true
  end

  config.after(:each) do
    Provenance::Context.cleanup
  end

  config.filter_run :focus
  config.run_all_when_everything_filtered = true
  config.warnings = true
end
