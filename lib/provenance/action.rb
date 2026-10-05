# frozen_string_literal: true

module Provenance
  # A unit of user intent: one HTTP request, job, rake task or explicit block.
  class Action
    # Accepted kinds.
    KINDS = %w[http job task custom].freeze
    # HTTP methods treated as reads.
    READ_METHODS = %w[GET HEAD].freeze
    # Maximum length of a recorded exception message.
    MESSAGE_LIMIT = 500

    # @return [String] UUIDv7
    attr_reader :id
    # @return [String]
    attr_reader :kind
    # @return [String, nil]
    attr_accessor :name
    # @return [String, nil] id of the action that caused this one
    attr_accessor :caused_by
    # @return [Context]
    attr_reader :context
    # @return [Hash] request attributes for HTTP actions
    attr_reader :request
    # @return [Hash{String => Object}]
    attr_reader :metadata
    # @return [Array<EntityChange>]
    attr_reader :changes
    # @return [Time]
    attr_reader :started_at
    # @return [Exception, nil]
    attr_reader :exception
    # @return [Actor, nil] actor set explicitly, without running the resolver
    attr_reader :explicit_actor

    # @param kind [Symbol, String]
    # @param name [String, nil]
    # @param actor [Object, nil]
    # @param metadata [Hash]
    # @param explicit [Boolean] explicit actions are always auditable
    # @param caused_by [String, nil]
    # @param context [Context, nil]
    def initialize(kind:, name:, actor: nil, metadata: {}, explicit: false, caused_by: nil, context: nil)
      @kind = kind.to_s
      raise ArgumentError, "unknown action kind #{kind.inspect}" unless KINDS.include?(@kind)

      @started_at = Time.now.utc
      @id = UUID.v7(@started_at)
      @name = name
      @explicit_actor = Actor.wrap(actor)
      @metadata = {}
      annotate(**metadata)
      @explicit = explicit
      @caused_by = caused_by
      @context = context || Context.new
      @request = {}
      @changes = []
      @lock = Mutex.new
      @skipped = false
    end

    # Merges data into the action metadata.
    #
    # @param data [Hash]
    # @return [self]
    def annotate(**data)
      @metadata.merge!(data.deep_stringify_keys)
      self
    end

    # @param value [Object, Hash, Actor, nil] anything {Actor.wrap} accepts
    def actor=(value)
      @explicit_actor = Actor.wrap(value)
    end

    # The actor, resolved through the configured resolver when not set explicitly.
    # Resolver failures are reported to +on_error+ and yield +nil+.
    #
    # @return [Actor, nil]
    def actor
      return @explicit_actor if @explicit_actor

      resolver = Provenance.config.actor_resolver
      return nil unless resolver

      resolved = Actor.wrap(resolver.call(context))
      @explicit_actor = resolved if resolved
      resolved
    rescue => e
      Provenance.config.report_error(e)
      nil
    end

    # @param change [EntityChange]
    # @return [void]
    def add_change(change)
      @lock.synchronize { @changes << change }
    end

    # Records an exception as the outcome. Only the first exception is kept.
    #
    # @param exception [Exception]
    # @return [void]
    def fail!(exception)
      @exception ||= exception
    end

    # Excludes this action from emission.
    #
    # @return [void]
    def skip!
      @skipped = true
    end

    # @return [Boolean]
    def skipped?
      @skipped
    end

    # @return [Boolean]
    def explicit?
      @explicit
    end

    # @return [String] "success", "failure" or "denied"
    def result
      if exception
        Provenance.config.denied?(exception) ? "denied" : "failure"
      else
        case request["status"].to_i
        when 401, 403 then "denied"
        when 500..599 then "failure"
        else "success"
        end
      end
    end

    # @return [Hash, nil] {"class", "message"} of the recorded exception
    def error
      return nil unless exception

      {"class" => exception.class.name, "message" => exception.message.to_s.truncate(MESSAGE_LIMIT)}
    end

    # @return [Boolean] whether an HTTP action used GET or HEAD
    def read?
      kind == "http" && READ_METHODS.include?(request["method"].to_s.upcase)
    end

    # Whether the action produces an event (section 4.4).
    #
    # @return [Boolean]
    def auditable?
      return false if skipped?

      changes.any? || result != "success" || (kind == "http" && !read?) ||
        Provenance.config.audit_reads || explicit?
    end
  end
end
