# frozen_string_literal: true

module EdgeSuite
  # Lossy time-series compression with a *hard* error bound — the swinging-door
  # / cone-intersection family used by industrial historians.
  #
  # Delta+RLE (Frame) shrinks what you send; this decides whether to send at
  # all. A slow signal sampled every 100 ms is mostly redundant: the receiver
  # can rebuild it by drawing straight lines between a handful of archived
  # points. SwingingDoor keeps only the points where that line would go wrong.
  #
  # How the bound is kept: from the current anchor point, every held sample
  # (t_i, v_i) constrains the slope of any line that stays within `deviation`
  # of it to the interval [(v_i - dev - v0)/dt_i, (v_i + dev - v0)/dt_i]. The
  # feasible slopes are the intersection of those intervals — the "doors",
  # swinging shut as samples accumulate. While the intersection is non-empty a
  # single segment can represent everything held. When a new sample empties it,
  # the segment is closed at the previous sample and a new anchor starts there.
  #
  # The closing endpoint is the real sample whenever its own slope is still
  # feasible (the usual case, so archived points are true readings); otherwise
  # the slope is clamped into the cone, which is what makes the guarantee
  # exact: every discarded sample lies within `deviation` of the reconstructed
  # piecewise-linear signal, always, not on average.
  #
  # Constant memory (one anchor, one held sample, two slopes) — the firmware
  # twin SwingingDoor.h runs the same recurrence on an MCU.
  class SwingingDoor
    Point = Struct.new(:t, :value)

    attr_reader :deviation, :max_interval, :seen, :emitted

    # deviation   maximum absolute reconstruction error, in sample units.
    #             0.0 is lossless-on-a-line: only genuine slope changes emit.
    # max_interval optional heartbeat: never let the archive go quiet for
    #             longer than this in t units, even on a perfectly flat signal.
    def initialize(deviation: 1.0, max_interval: nil)
      raise ArgumentError, "deviation must be >= 0" if deviation.negative?
      raise ArgumentError, "max_interval must be > 0" if max_interval && max_interval <= 0

      @deviation = deviation.to_f
      @max_interval = max_interval
      reset
    end

    def reset
      @anchor = nil
      @last = nil
      @seen = 0
      @emitted = 0
      open_full_cone
      self
    end

    # Feed one sample. Returns the Point that was archived by this sample (the
    # *previous* sample, or the very first one), or nil when the sample was
    # absorbed into the current segment. Timestamps must strictly increase.
    def update(t, value)
      validate!(t, value)
      @seen += 1
      t = t.to_f
      value = value.to_f

      if @anchor.nil?
        @anchor = Point.new(t, value)
        @last = @anchor
        @emitted += 1
        return @anchor
      end

      raise ArgumentError, "timestamps must increase (#{t} after #{@last.t})" if t <= @last.t

      dt = t - @anchor.t
      lo = (value - @deviation - @anchor.value) / dt
      hi = (value + @deviation - @anchor.value) / dt
      new_lo = lo > @lo ? lo : @lo
      new_hi = hi < @hi ? hi : @hi

      if new_lo > new_hi || heartbeat_due?(t)
        archived = close_segment
        @anchor = archived
        @last = Point.new(t, value)
        open_cone_for(@last)
        @emitted += 1
        return archived
      end

      @lo = new_lo
      @hi = new_hi
      @last = Point.new(t, value)
      nil
    end

    # Close the open segment at the end of a stream. Returns the final Point,
    # or nil when the last sample was already archived.
    def flush
      return nil if @anchor.nil? || @last.t == @anchor.t

      archived = close_segment
      @anchor = archived
      @last = archived
      open_full_cone
      @emitted += 1
      archived
    end

    # Archived points / samples seen. 0.05 means a 20x reduction.
    def compression_ratio
      @seen.zero? ? 1.0 : @emitted.to_f / @seen
    end

    # Compress a whole [[t, v], ...] series in one call (flush included).
    def self.compress(series, **opts)
      door = new(**opts)
      out = []
      series.each do |t, value|
        point = door.update(t, value)
        out << point if point
      end
      tail = door.flush
      out << tail if tail
      out
    end

    # Rebuild values at `times` (which must be non-decreasing) by linear
    # interpolation between archived points, holding the end values outside
    # the archived range. This is the decoder half of the bound.
    def self.reconstruct(points, times)
      return times.map { 0.0 } if points.empty?

      i = 0
      times.map do |t|
        i += 1 while i < points.length - 1 && points[i + 1].t <= t
        a = points[i]
        b = points[i + 1]
        if b.nil? || t <= a.t
          a.value.to_f
        else
          a.value + ((b.value - a.value) * (t - a.t) / (b.t - a.t).to_f)
        end
      end
    end

    # Worst absolute reconstruction error of `points` against the original
    # series — the quantity `deviation` bounds. Useful as an assertion in
    # tests and as a live quality metric on the gateway.
    def self.max_error(series, points)
      return 0.0 if series.empty?

      recon = reconstruct(points, series.map(&:first))
      series.each_with_index.map { |(_, v), i| (v - recon[i]).abs }.max
    end

    private

    def open_full_cone
      @lo = -Float::INFINITY
      @hi = Float::INFINITY
    end

    def open_cone_for(point)
      dt = point.t - @anchor.t
      return open_full_cone unless dt.positive?

      @lo = (point.value - @deviation - @anchor.value) / dt
      @hi = (point.value + @deviation - @anchor.value) / dt
    end

    # End the segment at the held sample, using its own value when that slope
    # is still inside the cone and a clamped one when it is not.
    def close_segment
      dt = @last.t - @anchor.t
      return @last unless dt.positive?

      direct = (@last.value - @anchor.value) / dt
      slope = direct < @lo ? @lo : (direct > @hi ? @hi : direct)
      return Point.new(@last.t, @last.value) if slope == direct

      Point.new(@last.t, @anchor.value + (slope * dt))
    end

    # Only meaningful once something is actually held: the heartbeat closes a
    # segment at the held sample, and there must be one distinct from the anchor.
    def heartbeat_due?(t)
      return false unless @max_interval
      return false unless @last.t > @anchor.t

      (t - @anchor.t) >= @max_interval
    end

    def validate!(t, value)
      raise ArgumentError, "t must be a finite number" unless
        t.is_a?(Numeric) && t.to_f.finite?
      raise ArgumentError, "value must be a finite number" unless
        value.is_a?(Numeric) && value.to_f.finite?
    end
  end
end
