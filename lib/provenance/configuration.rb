# frozen_string_literal: true

module Provenance
  # Global settings, see {Provenance.configure}.
  class Configuration
    # Accepted values for {#format}.
    FORMATS = %i[native ocsf cloudevents].freeze

    # Settings for tamper evidence (section 7 of the specification).
    class Integrity
      # @return [String, nil] HMAC-SHA256 key; +nil+ disables integrity
      attr_accessor :key

      # @return [Boolean]
      def enabled?
        key.present?
      end
    end

    # @return [Boolean] master switch; default +true+
    attr_accessor :enabled
    # @return [Array<Symbol, String, Regexp>] extra attributes to redact, merged with Rails filter_parameters
    attr_accessor :redact_attributes
    # @return [Array<String>] attributes never recorded in diffs; default +created_at+, +updated_at+
    attr_accessor :ignored_attributes
    # @return [Symbol] :native, :ocsf or :cloudevents
    attr_accessor :format
    # @return [Boolean] write events to the outbox table instead of delivering inline
    attr_accessor :outbox
    # @return [ActiveSupport::Duration] how long delivered outbox rows are kept
    attr_accessor :outbox_retention
    # @return [Integer] rows per relay batch
    attr_accessor :outbox_batch_size
    # @return [Boolean] enqueue {RelayJob} after each outbox write
    attr_accessor :outbox_enqueue_relay
    # @return [Boolean] emit successful GET/HEAD actions without changes
    attr_accessor :audit_reads
    # @return [Array<String>] exception class names that produce a +denied+ outcome
    attr_accessor :denied_exceptions
    # @return [Integer] maximum number of ids recorded for a bulk change
    attr_accessor :bulk_ids_limit
    # @return [Array<#deliver>] configured sinks
    attr_reader :sinks
    # @return [Integrity]
    attr_reader :integrity
    # @return [Proc, nil] actor resolver set with {#actor}
    attr_reader :actor_resolver
    # @return [Proc, nil] error handler set with {#on_error}
    attr_reader :error_handler
    # @return [Logger, nil] logger for diagnostics; defaults to Rails.logger
    attr_writer :logger
    # @return [String] application name
    attr_writer :app_name

    def initialize
      @enabled = true
      @redact_attributes = []
      @ignored_attributes = %w[created_at updated_at]
      @format = :native
      @sinks = []
      @outbox = false
      @outbox_retention = 7.days
      @outbox_batch_size = 100
      @outbox_enqueue_relay = true
      @integrity = Integrity.new
      @audit_reads = false
      @denied_exceptions = ["CanCan::AccessDenied", "Pundit::NotAuthorizedError"]
      @bulk_ids_limit = 500
    end

    # Application name used as the event +app+ and CloudEvents +source+. Defaults to
    # the Rails application module name, underscored.
    #
    # @return [String]
    def app_name
      @app_name ||= if defined?(Rails) && Rails.respond_to?(:application) && Rails.application
        Rails.application.class.module_parent_name.underscore
      else
        "app"
      end
    end

    # @return [Logger]
    def logger
      @logger || (defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger) || Logger.new($stderr)
    end

    # Sets the actor resolver. The block receives a {Context} and returns a user-like
    # object, a Hash or an {Actor}.
    #
    # @yieldparam ctx [Context]
    # @return [void]
    def actor(&block)
      @actor_resolver = block
    end

    # Sets the handler for sink and emission failures.
    #
    # @yieldparam exception [Exception]
    # @yieldparam event [Hash, nil]
    # @return [void]
    def on_error(&block)
      @error_handler = block
    end

    # Adds a sink. Accepts a built-in type (:logger, :io, :http, :proc, :memory,
    # :kafka) with its options, or any object responding to +#deliver(batch)+.
    #
    # @param type [Symbol, #deliver]
    # @return [#deliver] the sink instance
    def sink(type, *args, **options, &block)
      Sinks.build(type, *args, **options, &block).tap { |s| @sinks << s }
    end

    # Reports an error through the configured handler, falling back to the logger.
    #
    # @param exception [Exception]
    # @param event [Hash, nil]
    # @return [void]
    def report_error(exception, event = nil)
      if error_handler
        error_handler.call(exception, event)
      else
        logger.error("[provenance] #{exception.class}: #{exception.message}")
      end
    rescue => e
      logger.error("[provenance] error handler failed: #{e.class}: #{e.message}")
    end

    # @param exception [Exception]
    # @return [Boolean] whether the exception produces a +denied+ outcome
    def denied?(exception)
      names = Array(denied_exceptions).map(&:to_s)
      exception.class.ancestors.any? { |mod| names.include?(mod.name) }
    end

    # @raise [ConfigurationError]
    # @return [true]
    def validate!
      unless FORMATS.include?(format)
        raise ConfigurationError, "format must be one of #{FORMATS.join(", ")}, got #{format.inspect}"
      end
      if integrity.enabled? && !outbox
        raise ConfigurationError, "integrity requires the outbox (set c.outbox = true)"
      end
      unless bulk_ids_limit.is_a?(Integer) && bulk_ids_limit >= 0
        raise ConfigurationError, "bulk_ids_limit must be a non-negative Integer"
      end
      true
    end
  end
end
