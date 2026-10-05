# frozen_string_literal: true

require_relative "lib/provenance/version"

Gem::Specification.new do |spec|
  spec.name = "provenance"
  spec.version = Provenance::VERSION
  spec.authors = ["Ivan Nikolaev"]
  spec.email = ["ivan_n6_20@icloud.com"]

  spec.summary = "Action-level, tamper-evident audit events for Rails applications"
  spec.description = "Provenance records who did what, through which entry point, with what outcome " \
    "and which records changed: one event per HTTP request, job, rake task or explicit block, " \
    "delivered to SIEM, log pipelines and webhooks in native, OCSF or CloudEvents format."
  spec.homepage = "https://github.com/inikalaev/provenance"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/v2/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*", "schema/**/*", "README.md", "CHANGELOG.md", "LICENSE"]
  spec.require_paths = ["lib"]

  spec.add_dependency "activejob", ">= 7.2"
  spec.add_dependency "activerecord", ">= 7.2"
  spec.add_dependency "activesupport", ">= 7.2"
  spec.add_dependency "railties", ">= 7.2"
end
