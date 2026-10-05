# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module Provenance
  # Rails generators shipped with Provenance.
  module Generators
    # +rails g provenance:install+: creates the outbox migration and an initializer.
    class InstallGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      desc "Creates the provenance_outbox migration and config/initializers/provenance.rb"

      # @return [void]
      def create_migration_file
        migration_template "create_provenance_outbox.rb.tt", "db/migrate/create_provenance_outbox.rb"
      end

      # @return [void]
      def create_initializer
        template "initializer.rb.tt", "config/initializers/provenance.rb"
      end

      private

      def migration_version
        "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      end
    end
  end
end
