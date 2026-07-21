# frozen_string_literal: true

module EdgeSuite
  # Wire primitives mirroring arduino/.../EdgeCodec.h byte-for-byte:
  # LEB128 unsigned varint, 32-bit zigzag, and CRC-8/SMBUS. Any change here
  # must be made on the firmware side too, or frames stop round-tripping.
  module Codec
    module_function

    # Signed 32-bit -> unsigned, small magnitudes map to small numbers.
    def zigzag_encode(value)
      ((value << 1) ^ (value >> 31)) & 0xFFFFFFFF
    end

    def zigzag_decode(u)
      (u >> 1) ^ -(u & 1)
    end

    # Append an unsigned LEB128 varint to the byte array `bytes`.
    def put_varint(bytes, value)
      value &= 0xFFFFFFFF
      loop do
        byte = value & 0x7F
        value >>= 7
        byte |= 0x80 if value.positive?
        bytes << byte
        break unless value.positive?
      end
      bytes
    end

    # Read an unsigned LEB128 varint from `bytes` starting at `pos`.
    # Returns [value, next_pos]. Raises on truncated/malformed input.
    def get_varint(bytes, pos)
      result = 0
      shift = 0
      while shift <= 28
        raise DecodeError, "truncated varint" if pos >= bytes.length

        byte = bytes[pos]
        pos += 1
        result |= (byte & 0x7F) << shift
        return [result, pos] if (byte & 0x80).zero?

        shift += 7
      end
      raise DecodeError, "varint longer than 5 bytes"
    end

    # CRC-8/SMBUS (poly 0x07, init 0x00) over a byte enumerable.
    def crc8(bytes, crc = 0x00)
      bytes.each do |b|
        crc ^= b
        8.times do
          crc = crc.anybits?(0x80) ? ((crc << 1) ^ 0x07) & 0xFF : (crc << 1) & 0xFF
        end
      end
      crc
    end
  end
end
