# frozen_string_literal: true

require_relative "frame"
require_relative "anomaly_detector"
require_relative "adaptive_sampler"

module EdgeSuite
  # Coordinates a fleet of edge nodes. For each channel it keeps a server-side
  # anomaly detector and adaptive sampler (mirrors of the on-device state),
  # ingests frames, tracks bandwidth savings, and produces retuning
  # recommendations the fleet can be pushed back to.
  class Gateway
    # Per-channel rolling state and statistics.
    Channel = Struct.new(
      :id, :detector, :sampler, :frames, :samples,
      :frame_bytes, :raw_bytes, :anomalies, :last_interval, :last_value
    )

    def initialize(alpha: 0.1, threshold: 3.5, warmup: 20,
                   min_interval: 50, max_interval: 2000)
      @alpha = alpha
      @threshold = threshold
      @warmup = warmup
      @min_interval = min_interval
      @max_interval = max_interval
      @channels = {}
    end

    attr_reader :channels

    # Ingest one frame (hex String, binary String, or byte Array).
    # Returns a report Hash for that frame. `on_anomaly` yields (channel_id,
    # sample_index, value, score) for each anomalous sample if a block is given.
    def ingest(frame_input)
      bytes = normalize(frame_input)
      decoded = Frame.decode(bytes)
      ch = channel_for(decoded.channel)

      anomaly_hits = []
      decoded.samples.each_with_index do |value, idx|
        is_anom = ch.detector.update(value)
        interval = ch.sampler.update(value, anomaly: is_anom)
        ch.last_interval = interval
        ch.last_value = value
        if is_anom
          anomaly_hits << { index: idx, value: value, score: ch.detector.score }
          yield decoded.channel, idx, value, ch.detector.score if block_given?
        end
      end

      ch.frames += 1
      ch.samples += decoded.samples.length
      ch.frame_bytes += bytes.length
      ch.raw_bytes += decoded.samples.length * 2
      ch.anomalies += anomaly_hits.length

      {
        channel: decoded.channel,
        samples: decoded.samples.length,
        frame_flag_anomaly: decoded.anomaly?,
        compressed: decoded.compressed?,
        frame_bytes: bytes.length,
        raw_bytes: decoded.samples.length * 2,
        anomalies: anomaly_hits,
        recommended_interval: ch.last_interval
      }
    end

    # Aggregate stats + retuning advice for a channel (or all channels).
    def report(channel_id = nil)
      return @channels.keys.map { |id| report(id) } if channel_id.nil?

      ch = @channels[channel_id]
      return nil unless ch

      ratio = ch.raw_bytes.positive? ? ch.frame_bytes.to_f / ch.raw_bytes : 1.0
      {
        channel: ch.id,
        frames: ch.frames,
        samples: ch.samples,
        bytes_on_wire: ch.frame_bytes,
        bytes_uncompressed: ch.raw_bytes,
        compression_ratio: ratio.round(4),
        bandwidth_saved_pct: ((1.0 - ratio) * 100).round(2),
        anomalies: ch.anomalies,
        mean: ch.detector.mean.round(3),
        std: ch.detector.std.round(3),
        activity: ch.sampler.activity.round(3),
        recommended_interval_ms: ch.last_interval,
        recommendation: recommend(ch)
      }
    end

    private

    def channel_for(id)
      @channels[id] ||= Channel.new(
        id,
        AnomalyDetector.new(alpha: @alpha, threshold: @threshold, warmup: @warmup),
        AdaptiveSampler.new(min_interval: @min_interval, max_interval: @max_interval),
        0, 0, 0, 0, 0, @max_interval, 0
      )
    end

    # Simple closed-loop advice: if a channel is anomaly-heavy, suggest a lower
    # z-threshold is NOT needed; instead flag it for attention. If it is very
    # quiet, suggest relaxing cadence to save more energy.
    def recommend(ch)
      return "insufficient data" if ch.samples < @warmup

      anom_rate = ch.anomalies.to_f / ch.samples
      if anom_rate > 0.2
        "high anomaly rate (#{(anom_rate * 100).round(1)}%): inspect sensor/environment"
      elsif ch.sampler.activity < 1.0
        "signal quiet: safe to raise max_interval for more power savings"
      else
        "nominal"
      end
    end

    def normalize(input)
      case input
      when Array
        input
      when String
        s = input.strip
        # Hex line if it is all hex digits and even length; else treat as binary.
        if s.match?(/\A[0-9a-fA-F]+\z/) && s.length.even?
          [s].pack("H*").bytes
        else
          input.bytes
        end
      else
        raise ArgumentError, "unsupported frame input: #{input.class}"
      end
    end
  end
end
