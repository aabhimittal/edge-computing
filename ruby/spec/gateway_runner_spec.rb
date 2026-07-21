# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe EdgeSuite::GatewayRunner do
  # A transport that replays a fixed list of frames.
  ArrayTransport = Struct.new(:frames) do
    def each_frame
      frames.each { |f| yield f }
    end

    def close; end
  end

  def sim_frames(count, **opts)
    frames = []
    EdgeSuite::DeviceSimulator.new(**opts).run(count) { |hex| frames << hex }
    frames
  end

  it "ingests every frame from a transport into the gateway" do
    frames = sim_frames(500, seed: 5, anomaly_every: 0)
    runner = described_class.new
    runner.run(ArrayTransport.new(frames))
    total = runner.gateway.report.sum { |r| r[:samples] }
    expect(total).to eq(500)
  end

  it "records anomalies to the store and yields them to the caller" do
    Dir.mktmpdir do |dir|
      frames = sim_frames(2000, seed: 9, anomaly_every: 150, anomaly_size: 300)
      store = EdgeSuite::StatsStore.new(dir: dir)
      runner = described_class.new(store: store, snapshot_every: 10)
      yielded = 0
      runner.run(ArrayTransport.new(frames)) { yielded += 1 }
      store.close
      expect(yielded).to be > 0
      expect(store.anomaly_count).to eq(yielded)
    end
  end

  it "writes a snapshot the runner can reload" do
    Dir.mktmpdir do |dir|
      frames = sim_frames(300, seed: 1, anomaly_every: 0)
      store = EdgeSuite::StatsStore.new(dir: dir)
      described_class.new(store: store, snapshot_every: 10).run(ArrayTransport.new(frames))
      store.close
      snap = EdgeSuite::StatsStore.new(dir: dir).load_snapshot
      expect(snap[:channels].first[:samples]).to eq(300)
    end
  end

  it "skips a corrupt frame instead of aborting the stream" do
    good = sim_frames(64, seed: 2, anomaly_every: 0)
    frames = [good.first, "deadbeef", *good[1..]]
    errors = []
    runner = described_class.new
    runner.run(ArrayTransport.new(frames), on_error: ->(e, _f) { errors << e })
    expect(errors.length).to eq(1)
    expect(errors.first).to be_a(EdgeSuite::DecodeError)
    # All valid frames still counted.
    expect(runner.gateway.report.sum { |r| r[:frames] }).to eq(good.length)
  end
end
