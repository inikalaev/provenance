# frozen_string_literal: true

module Provenance
  # Tracking options of every model declared with +has_provenance+.
  class Registry
    # Options of one tracked model.
    Options = Struct.new(:only, :except, :redact, :associations, :ignore_if) do
      # @param attribute [String]
      # @return [Boolean] whether the attribute belongs in diffs
      def track?(attribute)
        return false if Provenance.config.ignored_attributes.map(&:to_s).include?(attribute)
        return only.include?(attribute) if only.present?

        !except.include?(attribute)
      end
    end

    def initialize
      @models = Concurrent::Map.new
    end

    # @param model [Class]
    # @param options [Options]
    # @return [Options]
    def register(model, options)
      @models[model.name] = options
    end

    # Options for the model or its closest tracked ancestor (STI).
    #
    # @param model [Class]
    # @return [Options, nil]
    def options_for(model)
      model.ancestors.each do |klass|
        next unless klass.is_a?(Class) && klass.name

        options = @models[klass.name]
        return options if options
      end
      nil
    end

    # @return [Array<String>] names of tracked models
    def model_names
      @models.keys
    end
  end
end
