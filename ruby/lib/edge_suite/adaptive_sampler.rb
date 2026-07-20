# frozen_string_literal: true

module EdgeSuite
  # Server-side twin of the firmware AdaptiveSampler. Tracks signal activity as
  # an EWMA of the absolute first difference and maps it to a sampling interval
  # (ms): quiet signals relax toward max_interval, lively ones tighten toward
  # min_interval. Lets the gateway predict and retune device cadence.
  class AdaptiveSampler
    attr_reader :activity

    def initialize(min_interval: 50, max_interval: 2000, ref_range: 50.0,
                   alpha: 0.2, gain: 1.0)
      @min = min_interval
      @max = max_interval
      @ref = ref_range <= 0 ? 1.0 : ref_range.to_f
      @alpha = alpha
      @gain = gain
      @activity = 0.0
      @last = 0.0
      @has = false
    end

    # Register a sample; returns the recommended interval (ms) to the next one.
    def update(x, anomaly: false)
      x = x.to_f
      if @has
        d = (x - @last).abs
        @activity += @alpha * (d - @activity)
      end
      @last = x
      @has = true

      return @min if anomaly

      norm = (@activity / @ref) * @gain
      norm = 0.0 if norm.negative?
      norm = 1.0 if norm > 1.0
      (@max - (@max - @min) * norm).round
    end
  end
end
