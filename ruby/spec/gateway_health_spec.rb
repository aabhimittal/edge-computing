# frozen_string_literal: true

require "spec_helper"
require "stringio"

RSpec.describe "gateway liveness and bounded state" do
  # A settled, quiet channel is told to sample at max_interval (2 s), so the
  # grading thresholds below are 3 x 2 s (stale) and 10 x 2 s (silent).
  def quiet_gateway(clock, **opts)
    gw = EdgeSuite::Gateway.new(clock: clock, **opts)
    gw.ingest(EdgeSuite::Frame.encode([100, 100, 100], channel: 1))
    gw
  end

  it "grades channels against the cadence it recommended to them" do
    now = 0.0
    gw = quiet_gateway(-> { now })

    expect(gw.health.first).to include(status: :ok, channel: 1, frames: 1)
    now = 7.0
    expect(gw.health.first[:status]).to eq(:stale)
    now = 25.0
    expect(gw.health.first).to include(status: :silent, silent_for: 25.0)
    expect(gw.silent_channels.map { |h| h[:channel] }).to eq([1])
  end

  it "does not call a fast-sampling channel late on the slow channel's clock" do
    now = 0.0
    gw = EdgeSuite::Gateway.new(clock: -> { now })
    # A lively signal drives the recommended interval down toward min_interval.
    gw.ingest(EdgeSuite::Frame.encode(Array.new(30) { |i| i.even? ? 0 : 900 }))
    fast = gw.health.first[:expected_interval_ms]
    expect(fast).to be < 500
    now = 5.0
    expect(gw.health.first[:status]).to eq(:silent)
  end

  it "reports arrival time and replays a capture on its recorded timing" do
    gw = EdgeSuite::Gateway.new
    gw.ingest(EdgeSuite::Frame.encode([1, 2, 3]), at: 1_000.0)
    expect(gw.report(1)[:last_seen]).to eq(1_000.0)
    expect(gw.health(now: 1_001.0).first[:status]).to eq(:ok)
    expect(gw.health(now: 9_999.0).first[:status]).to eq(:silent)
  end

  it "bounds channel state so a faulty node cannot exhaust memory" do
    gw = EdgeSuite::Gateway.new(max_channels: 2)
    gw.ingest(EdgeSuite::Frame.encode([1, 2, 3], channel: 1))
    gw.ingest(EdgeSuite::Frame.encode([1, 2, 3], channel: 2))
    gw.ingest(EdgeSuite::Frame.encode([4, 5, 6], channel: 1)) # touch 1: now newest
    gw.ingest(EdgeSuite::Frame.encode([1, 2, 3], channel: 3))

    expect(gw.channels.keys).to contain_exactly(1, 3)
    expect(gw.evictions).to eq(1)
    expect(gw.report(1)[:frames]).to eq(2) # the touched channel kept its history
    expect { EdgeSuite::Gateway.new(max_channels: 0) }.to raise_error(ArgumentError)
  end

  it "keeps unbounded channels by default" do
    gw = EdgeSuite::Gateway.new
    (1..50).each { |c| gw.ingest(EdgeSuite::Frame.encode([1, 2, 3], channel: c)) }
    expect(gw.channels.size).to eq(50)
    expect(gw.evictions).to eq(0)
  end
end

RSpec.describe EdgeSuite::Transport::ByteStream do
  let(:frames) do
    [EdgeSuite::Frame.encode([1, 2, 4, 8], channel: 1),
     EdgeSuite::Frame.encode(Array.new(30, 700), channel: 2)]
  end

  it "pulls frames out of a raw binary stream with noise in it" do
    wire = ([0xFF, 0xFF] + frames[0] + [0x00] + frames[1]).pack("C*")
    transport = described_class.new(StringIO.new(wire), chunk_size: 7)
    expect(transport.each_frame.to_a).to eq(frames)
    expect(transport.stats).to include(frames: 2, dropped_bytes: 3)
  end

  it "drops a trailing partial frame instead of yielding a bad one" do
    wire = (frames[0] + frames[1][0..4]).pack("C*")
    transport = described_class.new(StringIO.new(wire))
    expect(transport.each_frame.to_a).to eq([frames[0]])
  end

  it "is selectable through Transport.build and drives a GatewayRunner" do
    wire = frames.flatten.pack("C*")
    transport = EdgeSuite::Transport.build(raw: StringIO.new(wire))
    expect(transport).to be_a(described_class)

    gw = EdgeSuite::Gateway.new
    EdgeSuite::GatewayRunner.new(gateway: gw).run(transport)
    expect(gw.report.sum { |r| r[:samples] }).to eq(34)
  end

  it "reads a binary capture file by path" do
    require "tmpdir"
    path = File.join(Dir.mktmpdir, "capture.bin")
    File.binwrite(path, frames.flatten.pack("C*"))
    expect(EdgeSuite::Transport.build(raw: path).each_frame.to_a).to eq(frames)
  end
end
