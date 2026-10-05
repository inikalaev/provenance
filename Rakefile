# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"
require "rubocop/rake_task"

RSpec::Core::RakeTask.new(:spec)
RuboCop::RakeTask.new(:rubocop)

namespace :yard do
  desc "Fail unless every public object is documented"
  task :coverage do
    output = `bundle exec yard stats --list-undoc`
    puts output
    abort "YARD documentation coverage is below 100%" unless output.include?("100.00% documented")
  end
end

task default: %i[spec rubocop]
