# frozen_string_literal: true

module Provenance
  # What the actor resolver sees: whichever of controller, job, request and Rack env
  # are available for the current action.
  class Context
    # @return [ActionController::Metal, nil]
    attr_accessor :controller
    # @return [ActiveJob::Base, nil]
    attr_accessor :job
    # @return [Hash, nil] the Rack env
    attr_accessor :env

    # @param controller [ActionController::Metal, nil]
    # @param job [ActiveJob::Base, nil]
    # @param request [ActionDispatch::Request, nil]
    # @param env [Hash, nil]
    def initialize(controller: nil, job: nil, request: nil, env: nil)
      @controller = controller
      @job = job
      @request = request
      @env = env
    end

    # @return [ActionDispatch::Request, nil]
    def request
      @request ||= controller&.request || (env && ActionDispatch::Request.new(env))
    end
  end
end
