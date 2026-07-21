# frozen_string_literal: true

require_relative "gateway"

module EdgeSuite
  # Drives a Gateway from any Transport, optionally persisting to a StatsStore.
  # This is the glue behind the `edge-gateway` CLI: pull frames, ingest them,
  # log anomalies, and snapshot statistics every N frames so a long-running
  # gateway survives restarts without losing history.
  class GatewayRunner
    def initialize(gateway: Gateway.new, store: nil, snapshot_every: 50)
      @gateway = gateway
      @store = store
      @snapshot_every = snapshot_every
      @frames = 0
    end

    attr_reader :gateway, :store

    # Consume frames from `transport` until it ends. Yields (channel, index,
    # value, score) for each anomaly so a caller can print alerts. Decode errors
    # on a single frame are reported via `on_error` (default: warn) and skipped,
    # so one corrupt frame never kills the stream.
    def run(transport, on_error: method(:default_on_error))
      transport.each_frame do |frame|
        begin
          @gateway.ingest(frame) do |ch, idx, value, score|
            @store&.record_anomaly(channel: ch, index: idx, value: value, score: score)
            yield ch, idx, value, score if block_given?
          end
        rescue DecodeError => e
          on_error.call(e, frame)
          next
        end

        @frames += 1
        snapshot! if @store && (@frames % @snapshot_every).zero?
      end
      snapshot! if @store
    ensure
      transport.close if transport.respond_to?(:close)
    end

    # Force-write the current per-channel report to the store.
    def snapshot!
      @store&.write_snapshot(@gateway.report)
    end

    private

    def default_on_error(err, frame)
      warn "  skip (#{err.message}): #{frame.to_s[0, 24]}..."
    end
  end
end
