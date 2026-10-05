# frozen_string_literal: true

require "openssl"

module Provenance
  # Tamper evidence: a per-app HMAC-SHA256 chain over canonical JSON.
  #
  #   mac = HMAC-SHA256(key, prev + canonical_json(event without "integrity"))
  module Integrity
    module_function

    # Canonical JSON: object keys sorted, no insignificant whitespace.
    #
    # @param value [Object] JSON-like structure
    # @return [String]
    def canonical(value)
      JSON.generate(sort(value))
    end

    # @param key [String]
    # @param prev [String, nil] mac of the previous event
    # @param event [Hash] native event; an "integrity" member is ignored
    # @return [String] lowercase hex HMAC-SHA256
    def mac(key, prev, event)
      payload = stringify(event).except("integrity")
      OpenSSL::HMAC.hexdigest("SHA256", key.to_s, "#{prev}#{canonical(payload)}")
    end

    # Verifies a contiguous, seq-ordered list of events from one app. The +prev+ of
    # the first event is taken as given, so a pruned outbox still verifies.
    #
    # @param events [Array<Hash>] native events with an "integrity" member
    # @param key [String]
    # @return [Integer, nil] the first broken seq, or nil when the chain is intact
    def verify(events, key:)
      previous = nil
      events.each do |raw|
        event = stringify(raw)
        integrity = event["integrity"]
        expected_seq = previous ? previous["seq"] + 1 : nil
        return expected_seq || 0 unless integrity.is_a?(Hash) && integrity["seq"].is_a?(Integer)

        seq = integrity["seq"]
        return seq if previous && (seq != expected_seq || integrity["prev"] != previous["mac"])
        return seq unless secure_compare(mac(key, integrity["prev"], event), integrity["mac"].to_s)

        previous = integrity
      end
      nil
    end

    # @api private
    def secure_compare(a, b)
      a.bytesize == b.bytesize && OpenSSL.fixed_length_secure_compare(a, b)
    end

    # @api private
    def sort(value)
      case value
      when Hash then value.keys.map(&:to_s).sort.to_h { |k| [k, sort(value[k] || value[k.to_sym])] }
      when Array then value.map { |v| sort(v) }
      else value
      end
    end

    # @api private
    def stringify(value)
      case value
      when Hash then value.to_h { |k, v| [k.to_s, stringify(v)] }
      when Array then value.map { |v| stringify(v) }
      else value
      end
    end
  end
end
