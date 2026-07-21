# frozen_string_literal: true

require_relative "frame"
require_relative "anomaly_detector"
require_relative "adaptive_sampler"

module EdgeSuite
  # Generates a synthetic sensor stream and runs the exact on-device pipeline
  # (anomaly detection -> adaptive sampling -> batched compression) so the whole
  # framework can be exercised end-to-end without hardware. Emits the same hex
  # frames a real EdgeNode sketch would, ready to pipe into the Gateway.
  class DeviceSimulator
    DEFAULTS = {
      channel: 1,
      batch: 32,
      baseline: 512,     # e.g. mid-scale of a 10-bit ADC
      amplitude: 40.0,   # sine amplitude
      period: 120,       # samples per cycle
      noise: 3.0,        # gaussian noise stddev
      anomaly_every: 250, # inject a spike roughly this often (0 = never)
      anomaly_size: 250,  # spike magnitude
      seed: 1234
    }.freeze

    def initialize(**opts)
      @opts = DEFAULTS.merge(opts)
      @rng = Random.new(@opts[:seed])
      @detector = AnomalyDetector.new
      @sampler = AdaptiveSampler.new
      @t = 0
    end

    # Run for `count` samples, yielding each emitted frame as a hex String.
    # Returns a summary Hash. If no block is given, frames are collected.
    def run(count)
      frames = []
      sink = block_given? ? ->(f) { yield f } : ->(f) { frames << f }

      batch = []
      batch_anomaly = false
      emitted = 0

      count.times do
        value = next_sample
        anomaly = @detector.update(value)
        @sampler.update(value, anomaly: anomaly)

        batch << value
        batch_anomaly ||= anomaly

        if batch.length >= @opts[:batch] || (anomaly && batch.length >= 4)
          sink.call(emit(batch, batch_anomaly))
          emitted += 1
          batch = []
          batch_anomaly = false
        end
      end

      unless batch.empty?
        sink.call(emit(batch, batch_anomaly))
        emitted += 1
      end

      summary = { samples: count, frames: emitted }
      block_given? ? summary : summary.merge(collected: frames)
    end

    private

    # One synthetic int16 sample: sine + gaussian noise + occasional spike.
    def next_sample
      @t += 1
      base = @opts[:baseline]
      sine = @opts[:amplitude] * Math.sin(2 * Math::PI * @t / @opts[:period])
      noise = gaussian * @opts[:noise]
      value = base + sine + noise

      every = @opts[:anomaly_every]
      if every.positive? && (@t % every).zero?
        value += (@rng.rand < 0.5 ? -1 : 1) * @opts[:anomaly_size]
      end

      clamp_i16(value.round)
    end

    def emit(batch, anomaly)
      Frame.encode(batch, channel: @opts[:channel], anomaly: anomaly)
            .map { |b| format("%02x", b) }.join
    end

    # Box-Muller gaussian from the seeded RNG.
    def gaussian
      u1 = 1.0 - @rng.rand
      u2 = 1.0 - @rng.rand
      Math.sqrt(-2.0 * Math.log(u1)) * Math.cos(2 * Math::PI * u2)
    end

    def clamp_i16(v)
      return 32_767 if v > 32_767
      return(-32_768) if v < -32_768

      v
    end
  end
end
