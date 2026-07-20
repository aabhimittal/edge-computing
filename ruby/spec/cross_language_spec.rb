# frozen_string_literal: true

require "spec_helper"
require "open3"
require "tmpdir"

# Proves the firmware C++ encoder and the Ruby encoder emit byte-identical
# frames. Skips gracefully if no C++ compiler is available (e.g. minimal CI).
RSpec.describe "cross-language wire compatibility" do
  # Same batches, in the same order, as spec/cross_language_check.cpp.
  BATCHES = [
    { samples: [100, 101, 103, 106, 110], channel: 1, anomaly: false },
    { samples: Array.new(64, 512), channel: 1, anomaly: false },
    { samples: [512, 512, 515, 515, 500], channel: 1, anomaly: true },
    { samples: [-32_768, 32_767, 0, -100, 100, -32_768], channel: 3, anomaly: false },
    { samples: Array.new(40) { |i| i.even? ? 0 : 20_000 }, channel: 2, anomaly: false }
  ].freeze

  gpp = %w[g++ c++ clang++].find { |c| system("which #{c} > /dev/null 2>&1") }

  it "produces frames identical to the firmware EdgeCompressor", if: gpp do
    root = File.expand_path("..", __dir__)              # ruby/
    inc = File.expand_path("../arduino/libraries/EdgeSuite/src", root)
    src = File.join(__dir__, "cross_language_check.cpp")
    bin = File.join(Dir.tmpdir, "edge_xlang_check")

    out, err, status = Open3.capture3("#{gpp} -std=c++11 -I#{inc} #{src} -o #{bin}")
    raise "compile failed: #{err}" unless status.success?

    cpp_lines, run_err, run_status = Open3.capture3(bin)
    raise "run failed: #{run_err}" unless run_status.success?

    cpp_frames = cpp_lines.split("\n").map(&:strip).reject(&:empty?)
    ruby_frames = BATCHES.map do |b|
      EdgeSuite::Frame.encode(b[:samples], channel: b[:channel], anomaly: b[:anomaly])
                      .map { |x| format("%02x", x) }.join
    end

    expect(cpp_frames.length).to eq(ruby_frames.length)
    cpp_frames.zip(ruby_frames).each_with_index do |(c, r), i|
      expect(c).to(eq(r), "batch #{i}: firmware=#{c} ruby=#{r}")
      # And the Ruby decoder must recover the original samples from C++ bytes.
      expect(EdgeSuite::Frame.decode([c].pack("H*").bytes).samples).to eq(BATCHES[i][:samples])
    end
  end
end
