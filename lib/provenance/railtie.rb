# frozen_string_literal: true

require "rails/railtie"

module Provenance
  # Wires Provenance into a Rails application.
  class Railtie < Rails::Railtie
    initializer "provenance.middleware" do |app|
      app.middleware.insert_after ActionDispatch::RequestId, Provenance::Middleware
    end

    initializer "provenance.action_controller" do
      ActiveSupport.on_load(:action_controller) { include Provenance::Controller }
      ActiveSupport::Notifications.subscribe("process_action.action_controller") do |*, payload|
        Provenance::Controller::Subscriber.call(payload)
      end
    end

    initializer "provenance.active_job" do
      ActiveSupport.on_load(:active_job) { include Provenance::Job }
    end

    config.after_initialize do
      Provenance.config.validate!
    end

    rake_tasks do
      load File.expand_path("../tasks/provenance.rake", __dir__)
    end

    generators do
      require "generators/provenance/install/install_generator"
    end
  end
end
