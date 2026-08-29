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

    # Total byte length of the frame that starts at `pos`, derived from the
    # frame's own header (and, for a compressed body, a walk over its varint
    # tokens). The format carries no length prefix, so this is what makes it
    # self-delimiting — and what lets FrameStream cut frames out of a raw byte
    # stream that has no message boundaries.
    #
    # Raises IncompleteFrame when the buffer merely stops short of the end of
    # the frame (read more, then retry) and DecodeError when the header itself
    # is structurally impossible (resync instead). Pass `max_frame` to cap how
    # far a corrupt header may make the reader look ahead.
    def self.frame_length(bytes, pos = 0, max_frame: nil)
      raise IncompleteFrame, "need header" if bytes.length - pos < HEADER_LEN
      raise DecodeError, "bad magic" unless bytes[pos] == MAGIC0 && bytes[pos + 1] == MAGIC1
      raise DecodeError, "unsupported version #{bytes[pos + 2]}" unless bytes[pos + 2] == VERSION

      count = bytes[pos + 5] | (bytes[pos + 6] << 8)
      raise DecodeError, "zero sample count" if count.zero?

      body_len =
        if bytes[pos + 4].anybits?(FLAG_COMPRESSED)
          compressed_body_length(bytes, pos + HEADER_LEN, count - 1, max_frame)
        else
          (count - 1) * 2
        end

      total = HEADER_LEN + body_len + 1
      raise DecodeError, "frame longer than #{max_frame} bytes" if max_frame && total > max_frame
      raise IncompleteFrame, "need body" if pos + total > bytes.length

      total
    end

    # --- internal encoding helpers (see private_class_method below) ---

    # Walk the compressed token stream far enough to account for `need` deltas
    # and return the body length in bytes. Never scans past `max_frame`, so a
    # corrupt header cannot send the reader off into the rest of the buffer.
    def self.compressed_body_length(bytes, start, need, max_frame)
      pos = start
      have = 0
      limit = max_frame ? start + max_frame : nil
      while have < need
        raise DecodeError, "frame longer than #{max_frame} bytes" if limit && pos >= limit

        u, pos = scan_varint(bytes, pos)
        if u.zero?
          run, pos = scan_varint(bytes, pos)
          # A zero-length run advances the cursor without producing samples;
          # a stream of them would be an unbounded scan, so reject it.
          raise DecodeError, "zero-length run" if run.zero?

          have += run
        else
          have += 1
        end
      end
      pos - start
    end

    # Like Codec.get_varint, but distinguishes "buffer ends mid-varint"
    # (IncompleteFrame) from "malformed varint" (DecodeError).
    def self.scan_varint(bytes, pos)
      result = 0
      shift = 0
      while shift <= 28
        byte = bytes[pos]
        raise IncompleteFrame, "truncated varint" if byte.nil?

        pos += 1
        result |= (byte & 0x7F) << shift
        return [result, pos] if (byte & 0x80).zero?

        shift += 7
      end
      raise DecodeError, "varint longer than 5 bytes"
    end


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
                         :raw_deltas, :to_i16, :compressed_body_length,
                         :scan_varint
  end
end
