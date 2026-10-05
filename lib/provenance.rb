# frozen_string_literal: true

require "json"
require "securerandom"
require "active_support"
require "active_support/core_ext"
require "active_support/isolated_execution_state"
require "active_record"

require "provenance/version"
require "provenance/errors"
require "provenance/uuid"
require "provenance/json_safe"
require "provenance/configuration"
require "provenance/actor"
require "provenance/context"
require "provenance/entity_change"
require "provenance/action"
require "provenance/registry"
require "provenance/redactor"
require "provenance/event"
require "provenance/serializers"
require "provenance/sinks"
require "provenance/emitter"
require "provenance/recorder"
require "provenance/model"
require "provenance/middleware"
require "provenance/controller"
require "provenance/job"
require "provenance/rake"

# Provenance emits one action-level audit event per HTTP request, background job,
# rake task or explicit block, and delivers it to security and observability tooling.
#
# @example
#   Provenance.configure do |c|
#     c.sink :logger
#   end
module Provenance

  STATE_KEY = :provenance_action
  SUPPRESS_KEY = :provenance_suppressed
  private_constant :STATE_KEY, :SUPPRESS_KEY

  class << self
    # Yields the global configuration and validates it afterwards.
    #
    # @yieldparam config [Configuration]
    # @return [Configuration]
    # @raise [ConfigurationError] when the resulting configuration is invalid
    def configure
      yield config
      config.validate!
      config
    end

    # @return [Configuration] the global configuration
    def config
      @config ||= Configuration.new
    end

    # Replaces the global configuration with defaults. Mostly useful in tests.
    #
    # @return [Configuration]
    def reset_config!
      @config = Configuration.new
    end

    # @return [Registry] the registry of models tracked with +has_provenance+
    def registry
      @registry ||= Registry.new
    end

    # @return [Boolean] whether tracking is active for the current execution context
    def enabled?
      (config.enabled || Testing.capturing?) && !suppressed?
    end

    # @return [Boolean] whether tracking is suppressed by {without}
    def suppressed?
      ActiveSupport::IsolatedExecutionState[SUPPRESS_KEY].to_i.positive?
    end

    # The action currently open in this thread or fiber, if any.
    #
    # @return [Action, nil]
    def current
      ActiveSupport::IsolatedExecutionState[STATE_KEY]
    end

    # Opens an explicit action. Explicit actions are always auditable. Nested scopes
    # attach their changes and metadata to the outermost action.
    #
    # @param name [String] action name, e.g. "users.import"
    # @param actor [Object, Hash, Actor, nil] who performs the action
    # @param metadata [Hash] arbitrary JSON-safe data
    # @yieldparam action [Action]
    # @return [Object] the block's return value
    def action(name, actor: nil, metadata: {}, &block)
      raise ArgumentError, "a block is required" unless block

      track(kind: :custom, name: name, actor: actor, metadata: metadata, explicit: true, &block)
    end

    # Runs the block with change tracking and emission suppressed.
    #
    # @return [Object] the block's return value
    def without
      state = ActiveSupport::IsolatedExecutionState
      state[SUPPRESS_KEY] = state[SUPPRESS_KEY].to_i + 1
      yield
    ensure
      state[SUPPRESS_KEY] -= 1
    end

    # Runs the block inside an action of the given kind, or inside the already open
    # action when there is one. Used by the HTTP, job and rake integrations.
    #
    # @param kind [Symbol] :http, :job, :task or :custom
    # @param name [String, nil]
    # @param actor [Object, nil]
    # @param metadata [Hash]
    # @param explicit [Boolean]
    # @param caused_by [String, nil] id of the parent action
    # @param context [Context, nil]
    # @yieldparam action [Action]
    # @return [Object] the block's return value
    def track(kind:, name:, actor: nil, metadata: {}, explicit: false, caused_by: nil, context: nil)
      if (outer = current)
        outer.annotate(**metadata) if metadata.present?
        outer.actor = actor if actor && outer.explicit_actor.nil?
        return yield(outer)
      end

      action = Action.new(kind: kind, name: name, actor: actor, metadata: metadata,
        explicit: explicit, caused_by: caused_by, context: context)
      within(action) { yield(action) }
    end

    # Makes +action+ current for the duration of the block, records an unhandled
    # exception as the outcome and hands the action to the emitter afterwards.
    #
    # @param action [Action]
    # @return [Object] the block's return value
    def within(action)
      state = ActiveSupport::IsolatedExecutionState
      previous = state[STATE_KEY]
      state[STATE_KEY] = action
      begin
        yield
      rescue Exception => e # rubocop:disable Lint/RescueException
        action.fail!(e)
        raise
      ensure
        state[STATE_KEY] = previous
        Emitter.finish(action)
      end
    end
  end
end

require "provenance/testing"
require "provenance/railtie" if defined?(Rails::Railtie)
