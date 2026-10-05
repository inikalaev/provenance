# frozen_string_literal: true

module Provenance
  # Who performed an action.
  class Actor
    # @return [String, nil]
    attr_reader :id
    # @return [String, nil]
    attr_reader :type
    # @return [String, nil]
    attr_reader :display
    # @return [Array<String>]
    attr_reader :roles
    # @return [Actor, nil] the real user behind a "login as" session
    attr_reader :impersonator

    # Builds an actor from a user-like object, a Hash, an {Actor} or nil.
    #
    # Objects are read through +provenance_actor+ (returning a Hash) when defined,
    # otherwise through +id+, +provenance_display+/+email+/+name+ and +provenance_roles+.
    #
    # @param value [Object, Hash, Actor, nil]
    # @return [Actor, nil]
    def self.wrap(value)
      case value
      when nil then nil
      when Actor then value
      when Hash then new(**value.symbolize_keys.slice(:id, :type, :display, :roles, :impersonator))
      else
        return wrap(value.provenance_actor) if value.respond_to?(:provenance_actor)

        new(
          id: value.respond_to?(:id) ? value.id : nil,
          type: value.class.name,
          display: display_for(value),
          roles: value.respond_to?(:provenance_roles) ? value.provenance_roles : []
        )
      end
    end

    # @api private
    def self.display_for(value)
      %i[provenance_display email name].each do |m|
        return value.public_send(m) if value.respond_to?(m)
      end
      nil
    end

    # @param id [Object]
    # @param type [String, nil]
    # @param display [String, nil]
    # @param roles [Array]
    # @param impersonator [Object, nil] anything {wrap} accepts
    def initialize(id:, type: nil, display: nil, roles: [], impersonator: nil)
      @id = id&.to_s
      @type = type&.to_s
      @display = display&.to_s
      @roles = Array(roles).map(&:to_s)
      @impersonator = Actor.wrap(impersonator)
      freeze
    end

    # @return [Hash{String => Object}]
    def to_h
      {
        "id" => id,
        "type" => type,
        "display" => display,
        "roles" => roles,
        "impersonator" => impersonator&.to_h
      }
    end

    # @param other [Object]
    # @return [Boolean]
    def ==(other)
      other.is_a?(Actor) && other.to_h == to_h
    end
    alias_method :eql?, :==

    # @return [Integer]
    def hash
      to_h.hash
    end
  end
end
