# frozen_string_literal: true

require "generators/provenance/install/install_generator"

RSpec.describe Provenance::Generators::InstallGenerator do
  def generate(dir)
    expect { Rails::Generators.invoke("provenance:install", [], destination_root: dir) }
      .to output(/create_provenance_outbox/).to_stdout
  end

  it "creates the outbox migration and the initializer" do
    Dir.mktmpdir do |dir|
      generate(dir)
      migration = Dir[File.join(dir, "db/migrate/*_create_provenance_outbox.rb")].sole
      expect(File.read(migration)).to include("create_table :provenance_outbox").and include("ActiveRecord::Migration[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]")
      expect(File.read(File.join(dir, "config/initializers/provenance.rb"))).to include("Provenance.configure")
    end
  end

  it "creates a migration that builds a working outbox table" do
    Dir.mktmpdir do |dir|
      generate(dir)
      load Dir[File.join(dir, "db/migrate/*_create_provenance_outbox.rb")].sole
      connection = ActiveRecord::Base.connection
      ActiveRecord::Migration.suppress_messages do
        connection.drop_table(:provenance_outbox)
        CreateProvenanceOutbox.migrate(:up)
      end
      expect(connection.index_exists?(:provenance_outbox, %i[app seq], unique: true)).to be(true)
    ensure
      load File.expand_path("../dummy/schema.rb", __dir__)
    end
  end
end
