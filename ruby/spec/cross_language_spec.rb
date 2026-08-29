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

    lines = cpp_lines.split("\n").map(&:strip).reject(&:empty?)
    cpp_frames = lines.reject { |l| l.start_with?("rx", "sd") }
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

    verify_frame_stream(lines)
    verify_swinging_door(lines)
  end

  # Frame *bytes* matching is only half the contract: the two sides must also
  # agree on where frames begin in a noisy stream, or a resync on one end
  # recovers a different set of frames than the other.
  def verify_frame_stream(lines)
    wire = [0xFF, 0x00, 0x45] +
           EdgeSuite::Frame.encode([100, 101, 103, 106, 110], channel: 1) +
           corrupt(EdgeSuite::Frame.encode(Array.new(64, 512), channel: 1), 10) +
           EdgeSuite::Frame.encode([512, 512, 515, 515, 500], channel: 1, anomaly: true) +
           [0x45, 0x53, 0x09]

    frames, stats = EdgeSuite::FrameStream.scan(wire)
    ruby_rx = frames.map { |f| "rx #{f.map { |b| format('%02x', b) }.join}" }
    expect(lines.grep(/\Arx /)).to eq(ruby_rx)
    expect(ruby_rx.length).to eq(2) # the corrupted frame is rejected, not fixed

    cpp_stats = lines.grep(/\Arxstats /).first.split[1..].map(&:to_i)
    expect(cpp_stats).to eq([stats[:frames], stats[:crc_errors], stats[:dropped_bytes]])
  end

  # Same series, same door decisions: a node that archives points and a
  # gateway that predicts them must segment the signal identically.
  def verify_swinging_door(lines)
    series = (0...60).map do |i|
      value = if i < 20 then i * 10.0
              elsif i < 40 then 190.0
              else 190 - ((i - 40) * 7)
              end
      [i, value.to_f]
    end
    points = EdgeSuite::SwingingDoor.compress(series, deviation: 2.0)
    ruby_sd = "sd #{points.map { |p| p.t.to_i }.join(' ')}"
    expect(lines.grep(/\Asd /).first).to eq(ruby_sd)
    expect(EdgeSuite::SwingingDoor.max_error(series, points)).to be <= 2.0 + 1e-6
  end

  def corrupt(frame, index)
    out = frame.dup
    out[index] ^= 0xFF
    out
  end
end
