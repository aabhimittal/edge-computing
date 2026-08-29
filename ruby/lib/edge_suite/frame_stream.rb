# frozen_string_literal: true

require_relative "frame"

module EdgeSuite
  # Carves EdgeSuite frames out of an arbitrary byte stream.
  #
  # A radio or serial link does not hand you message boundaries. Reads split a
  # frame in half, line noise arrives between frames, a dropped byte corrupts
  # one, and the magic pair 'E','S' turns up inside a payload by chance. This
  # class buffers bytes and resynchronises on every one of those:
  #
  #   * scan forward to the next magic pair, counting the bytes skipped
  #   * size the frame from its own header (Frame.frame_length)
  #   * keep waiting if the frame is not complete yet
  #   * on a bad header or a failed CRC, step *one* byte past the false magic
  #     and scan again — so a real frame overlapping a false one is still found
  #
  # The buffer is bounded: a stream that never produces a valid frame drops its
  # oldest bytes rather than growing forever. Counters in #stats make link
  # quality observable (dropped_bytes and crc_errors are what a marginal
  # antenna looks like before frames stop arriving altogether).
  class FrameStream
    DEFAULT_MAX_FRAME = 1024
    DEFAULT_MAX_BUFFER = 64 * 1024
    COMPACT_THRESHOLD = 4096

    def initialize(max_frame: DEFAULT_MAX_FRAME, max_buffer: DEFAULT_MAX_BUFFER)
      raise ArgumentError, "max_frame must exceed the #{Frame::HEADER_LEN}-byte header" if
        max_frame <= Frame::HEADER_LEN
      raise ArgumentError, "max_buffer must be >= max_frame" if max_buffer < max_frame

      @max_frame = max_frame
      @max_buffer = max_buffer
      @buf = []
      @pos = 0
      @stats = { bytes_in: 0, frames: 0, dropped_bytes: 0, resyncs: 0,
                 crc_errors: 0, overflows: 0 }
    end

    attr_reader :stats

    # Feed a chunk (byte Array, binary String, or a single Integer byte) and get
    # back every frame it completed, each as a byte Array ready for
    # Gateway#ingest. Frames are also yielded if a block is given.
    def feed(chunk)
      bytes = to_bytes(chunk)
      @stats[:bytes_in] += bytes.length
      @buf.concat(bytes)
      trim_buffer!

      out = []
      while (frame = next_frame)
        out << frame
        yield frame if block_given?
      end
      compact!
      out
    end

    # Chainable form: stream << chunk << chunk.
    def <<(chunk)
      feed(chunk)
      self
    end

    # Bytes held back waiting for the rest of a frame.
    def pending
      @buf.length - @pos
    end

    def reset
      @buf = []
      @pos = 0
      self
    end

    # One-shot helper for a captured dump: returns [frames, stats].
    def self.scan(bytes, **opts)
      stream = new(**opts)
      frames = stream.feed(bytes)
      [frames, stream.stats]
    end

    private

    # Extract the next complete frame, or nil if more bytes are needed.
    def next_frame
      loop do
        idx = index_of_magic
        if idx.nil?
          drop_to(@buf.length) # nothing here can start a frame
          return nil
        end
        drop_to(idx)

        begin
          len = Frame.frame_length(@buf, @pos, max_frame: @max_frame)
        rescue IncompleteFrame
          return nil
        rescue DecodeError
          desync!
          next
        end

        candidate = @buf[@pos, len]
        begin
          Frame.decode(candidate)
        rescue DecodeError
          @stats[:crc_errors] += 1
          desync!
          next
        end

        @pos += len
        @stats[:frames] += 1
        return candidate
      end
    end

    # Index of the next plausible frame start, or nil. A lone MAGIC0 at the very
    # end of the buffer counts: its partner may be in the next chunk.
    def index_of_magic
      i = @pos
      last = @buf.length - 1
      while i <= last
        return i if @buf[i] == Frame::MAGIC0 && (i == last || @buf[i + 1] == Frame::MAGIC1)

        i += 1
      end
      nil
    end

    # Step past a false frame start. One byte, not the whole candidate: the
    # bytes we skip may themselves contain the beginning of a real frame.
    def desync!
      @stats[:resyncs] += 1
      drop_to(@pos + 1)
    end

    def drop_to(index)
      dropped = index - @pos
      return if dropped <= 0

      @stats[:dropped_bytes] += dropped
      @pos = index
    end

    # Keep the buffer bounded even if the link never yields a valid frame.
    def trim_buffer!
      excess = pending - @max_buffer
      return unless excess.positive?

      @stats[:overflows] += 1
      drop_to(@pos + excess)
    end

    def compact!
      return if @pos.zero?

      if @pos >= @buf.length
        @buf.clear
        @pos = 0
      elsif @pos > COMPACT_THRESHOLD
        @buf = @buf[@pos..]
        @pos = 0
      end
    end

    def to_bytes(chunk)
      case chunk
      when Integer then [chunk & 0xFF]
      when String then chunk.b.bytes
      when Array then chunk
      else raise ArgumentError, "unsupported chunk: #{chunk.class}"
      end
    end
  end
end
