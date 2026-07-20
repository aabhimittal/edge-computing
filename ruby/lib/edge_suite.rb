# frozen_string_literal: true

require_relative "edge_suite/version"

module EdgeSuite
  # Raised when a frame cannot be decoded (bad magic, CRC, or truncation).
  class DecodeError < StandardError; end
end

require_relative "edge_suite/codec"
require_relative "edge_suite/frame"
require_relative "edge_suite/anomaly_detector"
require_relative "edge_suite/adaptive_sampler"
require_relative "edge_suite/gateway"
require_relative "edge_suite/device_simulator"
