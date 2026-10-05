# frozen_string_literal: true

module Provenance
  # Rack middleware that opens an +http+ action per request and closes it once the
  # application has produced the response.
  class Middleware
    # @param app [#call]
    def initialize(app)
      @app = app
    end

    # @param env [Hash] Rack env
    # @return [Array] Rack response
    def call(env)
      return @app.call(env) if !Provenance.enabled? || Provenance.current

      action = Action.new(kind: :http, name: nil, context: Context.new(env: env))
      Provenance.within(action) do
        response = @app.call(env)
        action.request["status"] = response[0].to_i
        response
      ensure
        describe(action, env)
      end
    end

    private

    def describe(action, env)
      request = ActionDispatch::Request.new(env)
      action.request.merge!(
        "id" => env["action_dispatch.request_id"],
        "method" => request.request_method,
        "path" => request.path,
        "ip" => request.remote_ip,
        "user_agent" => request.user_agent
      )
      action.request["status"] ||= nil
      action.name ||= "#{request.request_method} #{request.path}"
    rescue => e
      Provenance.config.report_error(e)
    end
  end
end
