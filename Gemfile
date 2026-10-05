# frozen_string_literal: true

source "https://rubygems.org"

gemspec

rails_version = ENV.fetch("RAILS_VERSION", "8.0")

gem "rails", "~> #{rails_version}.0"

gem "json_schemer", "~> 2.3"
gem "pg", "~> 1.5"
gem "rake", "~> 13.0"
gem "rspec", "~> 3.13"
gem "sqlite3", (rails_version == "7.2") ? ">= 1.4" : ">= 2.1"
gem "standard", "~> 1.45"
gem "webmock", "~> 3.23"
gem "yard", "~> 0.9"
