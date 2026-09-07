# frozen_string_literal: true

require_relative "transport/stdin"
require_relative "transport/serial"
require_relative "transport/mqtt"
require_relative "transport/byte_stream"

module EdgeSuite
  # Frame sources for the gateway. Every transport exposes one method,
  # `each_frame { |frame| ... }`, yielding raw frame payloads (hex text or
  # binary) that Gateway#ingest can consume directly — so the gateway is
  # decoupled from where frames come from (stdin, serial, MQTT, ...).
  module Transport
    module_function

    # Build a transport from a small option Hash, e.g.
    #   Transport.build(serial: "/dev/ttyUSB0", baud: 115200)
    #   Transport.build(mqtt: "broker.local", topic: "edge/+/frames")
    #   Transport.build(raw: "capture.bin")      # binary stream or dump
    #   Transport.build({})                       # -> Stdin
    def build(opts = {})
      if opts[:serial]
        Serial.new(device: opts[:serial], baud: opts[:baud] || Serial::DEFAULT_BAUD)
      elsif opts[:raw]
        source = opts[:raw]
        io = source.is_a?(String) ? File.open(source, "rb") : source
        ByteStream.new(io, **stream_opts(opts))
      elsif opts[:mqtt]
        Mqtt.new(host: opts[:mqtt], port: opts[:port] || 1883,
                 topic: opts[:topic] || "edge/+/frames")
      else
        Stdin.new(opts[:io] || $stdin)
      end
    end

    def stream_opts(opts)
      out = {}
      out[:max_frame] = opts[:max_frame] if opts[:max_frame]
      out[:max_buffer] = opts[:max_buffer] if opts[:max_buffer]
      out
    end
  end
end
