# frozen_string_literal: true

module Provenance
  module Serializers
    # OCSF 1.x: one API Activity (class_uid 6003) event per action plus one Entity
    # Management (class_uid 3004) event per entity change. The README documents the
    # field mapping.
    module OCSF
      # OCSF schema version the events declare.
      VERSION = "1.3.0"
      # API Activity class.
      API_ACTIVITY = {class_uid: 6003, category_uid: 6, class_name: "API Activity", category_name: "Application Activity"}.freeze
      # Entity Management class.
      ENTITY_MANAGEMENT = {class_uid: 3004, category_uid: 3, class_name: "Entity Management", category_name: "Identity & Access Management"}.freeze
      # activity_id by HTTP method for API Activity.
      HTTP_ACTIVITIES = {"POST" => 1, "GET" => 2, "HEAD" => 2, "PUT" => 3, "PATCH" => 3, "DELETE" => 4}.freeze
      # activity_id by change operation for Entity Management.
      CHANGE_ACTIVITIES = {
        "create" => 1, "bulk_insert" => 1, "update" => 3, "bulk_update" => 3, "destroy" => 4, "bulk_delete" => 4
      }.freeze
      # Activity names for ids used above.
      ACTIVITY_NAMES = {1 => "Create", 2 => "Read", 3 => "Update", 4 => "Delete", 99 => "Other"}.freeze
      # status_id, status and severity_id by outcome.
      OUTCOMES = {
        "success" => [1, "Success", 1],
        "failure" => [2, "Failure", 2],
        "denied" => [2, "Failure", 3]
      }.freeze

      module_function

      # @param event [Hash] native event
      # @return [Array<Hash>] the API Activity event followed by Entity Management events
      def call(event)
        [api_activity(event)] + event["changes"].each_with_index.map { |change, i| entity_management(event, change, i) }
      end

      # @param event [Hash]
      # @return [Hash]
      def api_activity(event)
        request = event["request"] || {}
        activity_id = HTTP_ACTIVITIES.fetch(request["method"].to_s.upcase) { activity_from_changes(event["changes"]) }
        result = base(event, API_ACTIVITY, activity_id, event["id"])
        result["api"] = {
          "operation" => event.dig("action", "name"),
          "request" => {"uid" => request["id"] || event["id"]},
          "response" => response(event)
        }.compact
        result["src_endpoint"] = {"ip" => request["ip"]}.compact
        if event["request"]
          result["http_request"] = {
            "http_method" => request["method"], "url" => {"path" => request["path"]},
            "user_agent" => request["user_agent"], "uid" => request["id"]
          }.compact
          result["http_response"] = {"code" => request["status"]}.compact
        end
        result["resources"] = event["changes"].map { |c| {"type" => c["entity"], "uid" => c["entity_id"]}.compact }
        result
      end

      # @param event [Hash]
      # @param change [Hash]
      # @param index [Integer]
      # @return [Hash]
      def entity_management(event, change, index)
        activity_id = CHANGE_ACTIVITIES.fetch(change["operation"], 99)
        result = base(event, ENTITY_MANAGEMENT, activity_id, "#{event["id"]}/#{index}")
        result["activity_name"] = change["operation"].capitalize if activity_id == 99
        result["entity"] = {
          "name" => change["entity"], "type" => change["entity"], "uid" => change["entity_id"], "data" => change["diff"]
        }.compact
        result["unmapped"]["change"] = change.except("entity", "entity_id", "diff")
        result
      end

      # @api private
      def base(event, klass, activity_id, uid)
        status_id, status, severity_id = OUTCOMES.fetch(event.dig("outcome", "result"), [99, "Other", 1])
        {
          "category_uid" => klass[:category_uid], "category_name" => klass[:category_name],
          "class_uid" => klass[:class_uid], "class_name" => klass[:class_name],
          "activity_id" => activity_id, "activity_name" => ACTIVITY_NAMES[activity_id],
          "type_uid" => (klass[:class_uid] * 100) + activity_id,
          "time" => (Time.iso8601(event["occurred_at"]).to_r * 1000).to_i,
          "severity_id" => severity_id,
          "status_id" => status_id, "status" => status,
          "status_detail" => event.dig("outcome", "result"),
          "metadata" => {
            "version" => VERSION, "uid" => uid, "correlation_uid" => event["id"], "log_name" => event["app"],
            "product" => {"name" => "Provenance", "vendor_name" => "Provenance", "version" => Provenance::VERSION}
          },
          "actor" => actor(event["actor"], event["app"]),
          "unmapped" => {
            "action" => event["action"], "metadata" => event["metadata"],
            "impersonator" => event.dig("actor", "impersonator"), "integrity" => event["integrity"]
          }.compact
        }
      end

      # @api private
      def actor(actor, app)
        result = {"app_name" => app}
        if actor
          result["user"] = {
            "uid" => actor["id"], "name" => actor["display"], "type" => actor["type"],
            "groups" => Array(actor["roles"]).map { |role| {"name" => role} }
          }.compact
        end
        result
      end

      # @api private
      def response(event)
        error = event.dig("outcome", "error")
        response = {"code" => event.dig("request", "status")}
        response.merge!("error" => error["class"], "error_message" => error["message"]) if error
        response.compact.presence
      end

      # @api private
      def activity_from_changes(changes)
        ids = changes.map { |c| CHANGE_ACTIVITIES.fetch(c["operation"], 99) }.uniq
        (ids.size == 1) ? ids.first : 99
      end
    end
  end
end
