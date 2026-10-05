# frozen_string_literal: true

require_relative "dummy/application"
require "provenance/rspec"
require "json_schemer"
require "webmock/rspec"

Dir[File.join(__dir__, "support", "*.rb")].sort.each { |f| require f }

RSpec.configure do |config|
  config.example_status_persistence_file_path = ".rspec_status"
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed

  config.expect_with(:rspec) { |c| c.syntax = :expect }

  config.include SpecHelpers

  config.before do
    Provenance.reset_config!
    Provenance.configure do |c|
      c.app_name = "dummy"
      c.actor { |ctx| ctx.controller&.current_user }
      c.sink :memory
    end
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    ActiveJob::Base.queue_adapter.performed_jobs.clear
  end

  config.after do
    ActiveRecord::Base.connection.tables.each do |table|
      next if %w[schema_migrations ar_internal_metadata].include?(table)

      ActiveRecord::Base.connection.execute("DELETE FROM #{ActiveRecord::Base.connection.quote_table_name(table)}")
    end
  end
end
