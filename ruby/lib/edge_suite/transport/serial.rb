# frozen_string_literal: true

module EdgeSuite
  module Transport
    # Reads hex frames from a real serial port (e.g. /dev/ttyUSB0, /dev/ttyACM0,
    # COM3). Dependency-free: the tty is opened as an ordinary IO and read line
    # by line, exactly matching what EdgeNode.ino prints. On POSIX the baud rate
    # is set with `stty` before opening; that step is best-effort and skipped if
    # `stty` is unavailable or an IO is injected (tests pass a StringIO).
    class Serial
      DEFAULT_BAUD = 115_200

      def initialize(device:, baud: DEFAULT_BAUD, io: nil, configure: true)
        @device = device
        @baud = baud
        @io = io
        @configure = configure && io.nil?
        @owned = io.nil?
      end

      # Yields each non-empty hex frame line from the port until it closes/EOF.
      def each_frame
        return enum_for(:each_frame) unless block_given?

        configure_baud if @configure
        @io ||= File.open(@device, "rb")
        @io.each_line do |line|
          line = line.strip
          yield line unless line.empty?
        end
      end

      def close
        @io.close if @io && @owned && !@io.closed?
      end

      private

      # Best-effort POSIX baud/line configuration. Failures (Windows, no stty,
      # permission) are non-fatal: many adapters work at the default line rate.
      def configure_baud
        return unless File.exist?("/bin/stty") || system("which stty > /dev/null 2>&1")

        system("stty", "-F", @device, @baud.to_s, "raw", "-echo",
               out: File::NULL, err: File::NULL)
      rescue StandardError
        # ignore — proceed with whatever the port default is
      end
    end
  end
end
