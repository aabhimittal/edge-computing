# frozen_string_literal: true

require_relative "../frame_stream"

module EdgeSuite
  module Transport
    # Reads frames from a raw *binary* byte stream: a serial port in binary
    # mode, a socket, or a captured `.bin` dump. Unlike Stdin there are no line
    # boundaries to lean on — frames arrive back to back, split across reads,
    # with noise in between — so every chunk goes through a FrameStream, which
    # finds the boundaries and resynchronises after corruption.
    #
    # Binary is the cheaper wire: hex text doubles every frame, which on a
    # duty-cycled LoRa link is a real constraint, not an aesthetic one.
    class ByteStream
      DEFAULT_CHUNK = 512

      def initialize(io, chunk_size: DEFAULT_CHUNK, **stream_opts)
        @io = io
        @chunk_size = chunk_size
        @stream = FrameStream.new(**stream_opts)
      end

      attr_reader :stream

      # Yields each complete frame as a byte Array (Gateway#ingest takes those
      # directly). A partial frame left at EOF is simply never yielded.
      def each_frame
        return enum_for(:each_frame) unless block_given?

        @io.binmode if @io.respond_to?(:binmode)
        while (chunk = @io.read(@chunk_size))
          break if chunk.empty?

          @stream.feed(chunk) { |frame| yield frame }
        end
      end

      # Link-quality counters (frames, dropped_bytes, crc_errors, resyncs).
      def stats
        @stream.stats
      end

      def close
        @io.close if @io.respond_to?(:close) && !@io.closed?
      end
    end
  end
end
