# frozen_string_literal: true

module Provenance
  # Holds the global configuration: the data source name, the list of sensitive
  # attributes, the delivery hooks and the value providers used to enrich every
  # audit event.
  class Configuration
    attr_accessor :source_name, :sensitive_attributes, :audit_hooks, :enabled,
      :username_provider, :roles_provider, :remote_ip_provider, :origin_ip_provider, :session_id_provider,
      :track_bulk_operations, :bulk_operations_max_ids

    def initialize
      @source_name = "app_#{Rails.env}"
      @sensitive_attributes = []
      @audit_hooks = []
      @enabled = !Rails.env.test?
      @track_bulk_operations = false
      @bulk_operations_max_ids = 1000
      @username_provider = nil
      @roles_provider = nil
      @remote_ip_provider = nil
      @origin_ip_provider = nil
      @session_id_provider = nil
    end

    def add_audit_hook(&block)
      @audit_hooks << block
    end

    def clear_audit_hooks
      @audit_hooks.clear
    end
  end
end
