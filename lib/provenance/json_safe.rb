# frozen_string_literal: true

require "bigdecimal"

module Provenance
  # Converts arbitrary Ruby values into JSON-safe primitives.
  module JsonSafe
    module_function

    # @param value [Object]
    # @return [Object] a String, Numeric, true, false, nil, Array or Hash with String keys
    def call(value)
      case value
      when nil, true, false, Integer then value
      when Float then value.finite? ? value : value.to_s
      when BigDecimal then value.to_s("F")
      when String then string(value)
      when Symbol then value.to_s
      when Hash then value.each_with_object({}) { |(k, v), h| h[k.to_s] = call(v) }
      when Array, Set then value.map { |v| call(v) }
      when Time, DateTime, ActiveSupport::TimeWithZone then value.utc.iso8601(3)
      when Date then value.iso8601
      when ActiveSupport::Duration then value.iso8601
      when Numeric then value.to_s
      else value.respond_to?(:as_json) ? call(value.as_json) : value.to_s
      end
    end

    # @param value [String]
    # @return [String]
    def string(value)
      if value.encoding == Encoding::BINARY && !(value.ascii_only? && value.valid_encoding?)
        "[BINARY #{value.bytesize} bytes]"
      elsif value.valid_encoding?
        value
      else
        value.dup.force_encoding(Encoding::UTF_8).scrub
      end
    end
  end
end
