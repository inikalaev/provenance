# frozen_string_literal: true

module Provenance
  # One record-level change attached to an action.
  class EntityChange
    # Accepted operations.
    OPERATIONS = %w[create update destroy link unlink bulk_update bulk_delete bulk_insert].freeze

    # @return [String]
    attr_reader :entity
    # @return [String]
    attr_reader :operation
    # @return [Hash, nil] {attr => [before, after]}; create holds after values, destroy before values
    attr_reader :diff
    # @return [String, nil] association name for link/unlink
    attr_reader :association
    # @return [Hash, nil] {"type", "id"} of the linked record for link/unlink
    attr_reader :target
    # @return [Integer, nil] affected rows for bulk operations
    attr_reader :count
    # @return [String, nil] fingerprint of the WHERE clause for bulk operations
    attr_reader :where
    # @return [Array<String>, nil] affected ids for bulk operations
    attr_reader :ids
    # @return [Boolean, nil] whether {#ids} was cut at +bulk_ids_limit+
    attr_reader :truncated

    # @param entity [String]
    # @param operation [String, Symbol]
    # @param entity_id [Object, Proc] a Proc is evaluated when the event is built
    def initialize(entity:, operation:, entity_id: nil, diff: nil, association: nil, target: nil,
      count: nil, where: nil, ids: nil, truncated: nil)
      @entity = entity.to_s
      @operation = operation.to_s
      raise ArgumentError, "unknown operation #{operation.inspect}" unless OPERATIONS.include?(@operation)

      @entity_id = entity_id
      @diff = diff
      @association = association&.to_s
      @target = target
      @count = count
      @where = where
      @ids = ids
      @truncated = truncated
    end

    # @return [String, nil]
    def entity_id
      value = @entity_id.is_a?(Proc) ? @entity_id.call : @entity_id
      value&.to_s
    end

    # @return [Hash, nil] {#target} with lazily computed ids evaluated
    def resolved_target
      target&.transform_values { |v| v.is_a?(Proc) ? v.call&.to_s : v }
    end

    # @return [Boolean]
    def bulk?
      operation.start_with?("bulk_")
    end

    # @return [Hash{String => Object}] JSON-safe representation
    def to_h
      h = {"entity" => entity, "entity_id" => entity_id, "operation" => operation, "diff" => JsonSafe.call(diff)}
      h.merge!("association" => association, "target" => JsonSafe.call(resolved_target)) if association
      if bulk?
        h.merge!("count" => count, "where" => where, "ids" => Array(ids).map(&:to_s), "truncated" => truncated ? true : false)
      end
      h
    end
  end
end
