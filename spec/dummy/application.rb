# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"
ENV["DATABASE_URL"] ||= "sqlite3::memory:"

require "rails"
require "active_record/railtie"
require "action_controller/railtie"
require "active_job/railtie"
require "provenance"

module Dummy
  class Application < Rails::Application
    config.root = __dir__
    config.load_defaults Rails::VERSION::STRING.to_f
    config.eager_load = false
    config.logger = Logger.new(nil)
    config.secret_key_base = "a" * 64
    config.hosts.clear
    config.active_job.queue_adapter = :test
    config.action_dispatch.show_exceptions = :all
    config.filter_parameters += %i[passw secret]
    config.active_record.encryption.primary_key = "p" * 32
    config.active_record.encryption.deterministic_key = "d" * 32
    config.active_record.encryption.key_derivation_salt = "s" * 32
  end
end

Rails.application.initialize!

require_relative "schema"
require_relative "models"
require_relative "controllers"
require_relative "jobs"

Rails.application.routes.draw do
  resources :invoices, only: %i[index show create update destroy] do
    member do
      post :boom
      post :forbidden
      post :rescued_forbidden
      post :tag
      get :peek
    end
  end
  get "health" => "health#show"
  post "health" => "health#create"
  post "admin/reports" => "admin/reports#create"
  post "admin/reports/preview" => "admin/reports#preview"
end
