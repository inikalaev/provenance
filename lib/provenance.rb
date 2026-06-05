# frozen_string_literal: true

require "active_support"
require "active_support/core_ext/module/attribute_accessors"
require "active_support/core_ext/hash/keys"
require "json"
require "logger"
require "rails"

require_relative "provenance/version"
require_relative "provenance/configuration"
require_relative "provenance/context"
require_relative "provenance/transaction_key"
require_relative "provenance/journal"
require_relative "provenance/trackers/providers"
require_relative "provenance/trackers/trackable"
require_relative "provenance/trackers/bulk_operations"
require_relative "provenance/trackers/auditable"
require_relative "provenance/trackers/error_reporting"

# Provenance is a self-contained audit trail for Rails applications. It records
# user actions and model changes, sanitizes sensitive data and ships the
# resulting events to any sink you configure through audit hooks.
module Provenance
  class Error < StandardError; end

  class << self
    def configure
      yield config
    end

    def config
      @config ||= Configuration.new
    end

    def setup_username_provider(provider)
      config.username_provider = provider
    end

    def setup_roles_provider(provider)
      config.roles_provider = provider
    end

    def setup_remote_ip_provider(provider)
      config.remote_ip_provider = provider
    end

    def setup_origin_ip_provider(provider)
      config.origin_ip_provider = provider
    end

    def setup_session_id_provider(provider)
      config.session_id_provider = provider
    end
  end
end
