# frozen_string_literal: true

module Provenance
  # UUIDv7 generation (RFC 9562): 48-bit Unix millisecond timestamp followed by
  # random bits, so ids sort by creation time.
  module UUID
    module_function

    # @param time [Time] timestamp to embed
    # @return [String] a UUIDv7 in canonical 8-4-4-4-12 form
    def v7(time = Time.now)
      ms = (time.to_r * 1000).to_i
      bytes = [ms >> 16, ms & 0xffff].pack("Nn").b + SecureRandom.random_bytes(10)
      bytes.setbyte(6, (bytes.getbyte(6) & 0x0f) | 0x70)
      bytes.setbyte(8, (bytes.getbyte(8) & 0x3f) | 0x80)
      hex = bytes.unpack1("H*")
      [hex[0, 8], hex[8, 4], hex[12, 4], hex[16, 4], hex[20, 12]].join("-")
    end
  end
end
