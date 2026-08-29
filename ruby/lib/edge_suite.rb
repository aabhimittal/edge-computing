# frozen_string_literal: true

require_relative "edge_suite/version"

module EdgeSuite
  # Raised when a frame cannot be decoded (bad magic, CRC, or truncation).
  class DecodeError < StandardError; end

  # Raised when the bytes seen so far are a valid *prefix* of a frame: nothing
  # is wrong, there is simply not enough data yet. It is a DecodeError subclass
  # so existing `rescue DecodeError` callers keep working, but a streaming
  # reader can tell "wait for more bytes" apart from "this is garbage".
  class IncompleteFrame < DecodeError; end
end

require_relative "edge_suite/codec"
require_relative "edge_suite/frame"
require_relative "edge_suite/frame_stream"
require_relative "edge_suite/swinging_door"
require_relative "edge_suite/anomaly_detector"
require_relative "edge_suite/adaptive_sampler"
require_relative "edge_suite/gateway"
require_relative "edge_suite/device_simulator"
require_relative "edge_suite/transport"
require_relative "edge_suite/stats_store"
require_relative "edge_suite/gateway_runner"
