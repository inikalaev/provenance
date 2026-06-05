# frozen_string_literal: true

lib = File.expand_path("lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "provenance/version"

Gem::Specification.new do |s|
  s.name = "provenance"
  s.version = Provenance::VERSION
  s.authors = ["Ivan Nikolaev"]
  s.email = ["ivan_n6_20@icloud.com"]
  s.license = "MIT"

  s.summary = "Audit trail for Rails: user actions and model changes"
  s.description = <<~DESC
    Provenance records user actions and ActiveRecord model changes in Rails
    applications. It groups changes per request and transaction, sanitizes
    sensitive data, tracks bulk operations and has_and_belongs_to_many changes,
    and ships structured audit events to any sink through configurable hooks.
  DESC

  s.homepage = "https://github.com/inikalaev/provenance"
  s.required_ruby_version = ">= 3.2.2"

  s.metadata = {
    "homepage_uri" => s.homepage,
    "source_code_uri" => s.homepage,
    "changelog_uri" => "#{s.homepage}/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "#{s.homepage}/issues",
    "rubygems_mfa_required" => "true"
  }

  s.files = Dir["lib/**/*.rb"] + %w[README.md CHANGELOG.md LICENSE]
  s.require_paths = ["lib"]

  # Runtime dependencies
  s.add_dependency "actionpack", ">= 6.0"
  s.add_dependency "activerecord", ">= 6.0"
  s.add_dependency "activesupport", ">= 6.0"
  s.add_dependency "rails", ">= 6.0"
end
