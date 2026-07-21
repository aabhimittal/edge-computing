# frozen_string_literal: true

require_relative "transport/stdin"
require_relative "transport/serial"
require_relative "transport/mqtt"

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
    #   Transport.build({})                       # -> Stdin
    def build(opts = {})
      if opts[:serial]
        Serial.new(device: opts[:serial], baud: opts[:baud] || Serial::DEFAULT_BAUD)
      elsif opts[:mqtt]
        Mqtt.new(host: opts[:mqtt], port: opts[:port] || 1883,
                 topic: opts[:topic] || "edge/+/frames")
      else
        Stdin.new(opts[:io] || $stdin)
      end
    end
  end
end
