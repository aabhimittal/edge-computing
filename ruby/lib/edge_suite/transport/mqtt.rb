# frozen_string_literal: true

module EdgeSuite
  module Transport
    # Receives frames from an MQTT broker — the usual fan-in point for a LoRa or
    # Wi-Fi fleet, where each gateway/bridge republishes device frames onto a
    # topic. Payloads may be raw binary frames or hex text; both are accepted
    # (Gateway#ingest auto-detects).
    #
    # The pure-Ruby `mqtt` gem is loaded lazily so it is only required when this
    # transport is actually used. A client may be injected for tests or to reuse
    # an existing connection; it must respond to #subscribe(topic) and #get
    # (yielding [topic, payload]).
    class Mqtt
      def initialize(host: "localhost", port: 1883, topic: "edge/+/frames",
                     client: nil)
        @host = host
        @port = port
        @topic = topic
        @client = client
        @owned = client.nil?
      end

      # Subscribes and yields each frame payload as it arrives. Blocks until the
      # client is closed or the connection ends.
      def each_frame
        return enum_for(:each_frame) unless block_given?

        client = (@client ||= connect)
        client.subscribe(@topic)
        client.get do |_topic, payload|
          frame = normalize_payload(payload)
          yield frame unless frame.nil? || frame.empty?
        end
      end

      def close
        @client.disconnect if @owned && @client.respond_to?(:disconnect)
      end

      # A payload is passed through untouched — Gateway#ingest handles both hex
      # strings and binary. Trailing newlines from line-oriented bridges are
      # trimmed so hex detection is not thrown off.
      def normalize_payload(payload)
        return payload if payload.nil?

        payload.is_a?(String) ? payload.strip : payload
      end

      private

      def connect
        require "mqtt"
        MQTT::Client.connect(host: @host, port: @port)
      rescue LoadError
        raise LoadError, "MQTT transport needs the 'mqtt' gem: gem install mqtt"
      end
    end
  end
end
