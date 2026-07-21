# frozen_string_literal: true

module EdgeSuite
  module Transport
    # Reads newline-delimited hex frames from an IO (defaults to $stdin) — the
    # format an EdgeNode sketch prints over Serial. This is the zero-dependency
    # default transport used by `edge-gateway` when no source flag is given.
    class Stdin
      def initialize(io = $stdin)
        @io = io
      end

      # Yields each non-empty frame line (leading/trailing whitespace stripped).
      def each_frame
        return enum_for(:each_frame) unless block_given?

        @io.each_line do |line|
          line = line.strip
          yield line unless line.empty?
        end
      end

      def close; end
    end
  end
end
