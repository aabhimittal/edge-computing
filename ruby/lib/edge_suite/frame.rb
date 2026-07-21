# frozen_string_literal: true

require_relative "codec"

module EdgeSuite
  # Encode/decode the EdgeSuite frame — the exact format produced by the
  # firmware's EdgeCompressor. See EdgeCompressor.h for the field-by-field
  # layout; this class is its inverse (plus a matching encoder for tests and
  # the simulator).
  #
  # A decoded frame is a Struct with: channel, flags, anomaly?, compressed?,
  # and samples (Array<Integer> of reconstructed int16 values).
  class Frame
    MAGIC0 = 0x45 # 'E'
    MAGIC1 = 0x53 # 'S'
    VERSION = 1
    FLAG_COMPRESSED = 0x01
    FLAG_ANOMALY = 0x02
    HEADER_LEN = 9

    Decoded = Struct.new(:channel, :flags, :samples) do
      def anomaly?
        flags.anybits?(FLAG_ANOMALY)
      end

      def compressed?
        flags.anybits?(FLAG_COMPRESSED)
      end
    end

    # Build a frame (Array<Integer> of bytes) from int16 samples. Mirrors the
    # firmware's raw-vs-compressed size choice so encoder output matches.
    def self.encode(samples, channel: 1, anomaly: false)
      raise ArgumentError, "need at least one sample" if samples.empty?

      count = samples.length
      compressed_body = compress_body(samples)
      raw_body = raw_body(samples)

      use_compressed = compressed_body.length < raw_body.length
      body = use_compressed ? compressed_body : raw_body

      flags = 0
      flags |= FLAG_COMPRESSED if use_compressed
      flags |= FLAG_ANOMALY if anomaly

      first = samples[0] & 0xFFFF
      header = [
        MAGIC0, MAGIC1, VERSION, channel & 0xFF, flags,
        count & 0xFF, (count >> 8) & 0xFF,
        first & 0xFF, (first >> 8) & 0xFF
      ]
      frame = header + body
      frame << Codec.crc8(frame)
      frame
    end

    # Decode a frame (Array<Integer> or binary String) into a Decoded struct.
    def self.decode(input)
      bytes = input.is_a?(String) ? input.bytes : input.to_a
      raise DecodeError, "frame too short" if bytes.length < HEADER_LEN + 1
      raise DecodeError, "bad magic" unless bytes[0] == MAGIC0 && bytes[1] == MAGIC1
      raise DecodeError, "unsupported version #{bytes[2]}" unless bytes[2] == VERSION

      expected_crc = bytes[-1]
      actual_crc = Codec.crc8(bytes[0...-1])
      raise DecodeError, "crc mismatch" unless expected_crc == actual_crc

      channel = bytes[3]
      flags = bytes[4]
      count = bytes[5] | (bytes[6] << 8)
      first = to_i16(bytes[7] | (bytes[8] << 8))
      body = bytes[HEADER_LEN...-1]

      deltas =
        if flags.anybits?(FLAG_COMPRESSED)
          decompress_deltas(body, count - 1)
        else
          raw_deltas(body, count - 1)
        end

      samples = [first]
      deltas.each { |d| samples << to_i16((samples.last + d) & 0xFFFF) }
      raise DecodeError, "sample count mismatch" unless samples.length == count

      Decoded.new(channel, flags, samples)
    end

    # --- internal encoding helpers (see private_class_method below) ---

    def self.compress_body(samples)
      body = []
      i = 1
      while i < samples.length
        d = samples[i] - samples[i - 1]
        if d.zero?
          run = 0
          while i < samples.length && (samples[i] - samples[i - 1]).zero?
            run += 1
            i += 1
          end
          Codec.put_varint(body, 0)
          Codec.put_varint(body, run)
        else
          Codec.put_varint(body, Codec.zigzag_encode(d))
          i += 1
        end
      end
      body
    end

    def self.raw_body(samples)
      body = []
      (1...samples.length).each do |i|
        d = samples[i] - samples[i - 1]
        body << (d & 0xFF)
        body << ((d >> 8) & 0xFF)
      end
      body
    end

    def self.decompress_deltas(body, need)
      deltas = []
      pos = 0
      while deltas.length < need
        raise DecodeError, "truncated body" if pos >= body.length

        u, pos = Codec.get_varint(body, pos)
        if u.zero?
          run, pos = Codec.get_varint(body, pos)
          run.times { deltas << 0 }
        else
          deltas << Codec.zigzag_decode(u)
        end
      end
      deltas
    end

    def self.raw_deltas(body, need)
      deltas = []
      need.times do |k|
        lo = body[k * 2]
        hi = body[k * 2 + 1]
        raise DecodeError, "truncated raw body" if lo.nil? || hi.nil?

        deltas << to_i16(lo | (hi << 8))
      end
      deltas
    end

    def self.to_i16(u)
      u &= 0xFFFF
      u >= 0x8000 ? u - 0x10000 : u
    end

    private_class_method :compress_body, :raw_body, :decompress_deltas,
                         :raw_deltas, :to_i16
  end
end
