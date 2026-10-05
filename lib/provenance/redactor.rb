# frozen_string_literal: true

module Provenance
  # Replaces sensitive values with "[REDACTED]".
  module Redactor
    # Replacement for redacted values.
    MASK = "[REDACTED]"

    module_function

    # @return [Array<Symbol, String, Regexp, Proc>] configured redactions merged with Rails filter_parameters
    def filters
      rails = (defined?(Rails) && Rails.respond_to?(:application) && Rails.application&.config&.filter_parameters) || []
      Array(rails) + Array(Provenance.config.redact_attributes)
    end

    # @param name [String, Symbol]
    # @param extra [Array<String>] exact attribute names to redact
    # @return [Boolean]
    def redact?(name, extra = [])
      return true if extra.include?(name.to_s)

      filtered = parameter_filter.filter(name.to_s => true)
      filtered[name.to_s] != true
    end

    # Redacts a diff, keeping its shape.
    #
    # @param diff [Hash, nil]
    # @param extra [Array<String>]
    # @return [Hash, nil]
    def diff(diff, extra = [])
      return diff unless diff.is_a?(Hash)

      diff.to_h do |key, value|
        next [key, value] unless redact?(key, extra)

        [key, if value.is_a?(Array)
                value.map { |v| v.nil? ? nil : MASK }
              else
                MASK
              end]
      end
    end

    # Redacts nested hashes such as metadata.
    #
    # @param hash [Hash]
    # @return [Hash]
    def deep(hash)
      parameter_filter.filter(hash)
    end

    # @api private
    def parameter_filter
      current = filters
      cached = @parameter_filter
      return cached.last if cached && cached.first == current

      ActiveSupport::ParameterFilter.new(current, mask: MASK).tap { |f| @parameter_filter = [current, f] }
    end
  end
end
