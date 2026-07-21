# frozen_string_literal: true

module EdgeSuite
  # Server-side twin of the firmware AnomalyDetector. Same EWMA mean and West
  # incremental EWMA variance recurrence, so device and gateway agree on what
  # is anomalous. O(1) memory; feed it one sample at a time.
  class AnomalyDetector
    attr_reader :mean, :variance, :score, :count

    def initialize(alpha: 0.1, threshold: 3.5, warmup: 20)
      @alpha = alpha
      @threshold = threshold
      @warmup = warmup
      @mean = 0.0
      @variance = 0.0
      @count = 0
      @score = 0.0
    end

    # Feed one sample; returns true if it is anomalous.
    #
    # Predict-then-update: the sample is scored against the estimate as it
    # stood *before* this sample, so an outlier cannot inflate its own variance
    # and mask itself. The estimate is folded in afterward.
    def update(x)
      x = x.to_f
      @count += 1
      if @count == 1
        @mean = x
        @variance = 0.0
        @score = 0.0
        return false
      end

      sd = Math.sqrt(@variance)
      @score = sd > 1e-6 ? (x - @mean) / sd : 0.0
      is_anomaly = @count > @warmup && @score.abs > @threshold

      diff = x - @mean
      incr = @alpha * diff
      @mean += incr
      @variance = (1.0 - @alpha) * (@variance + diff * incr)

      is_anomaly
    end

    def std
      Math.sqrt(@variance)
    end
  end
end
