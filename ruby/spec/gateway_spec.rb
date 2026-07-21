# frozen_string_literal: true

require "spec_helper"

RSpec.describe EdgeSuite::Gateway do
  it "ingests frames from the simulator and reconstructs samples" do
    sim = EdgeSuite::DeviceSimulator.new(seed: 5, anomaly_every: 0)
    gw = described_class.new
    total = 0
    sim.run(500) { |hex| total += gw.ingest(hex)[:samples] }
    expect(total).to eq(500)
  end

  it "accounts real bandwidth savings on a compressible signal" do
    sim = EdgeSuite::DeviceSimulator.new(seed: 5, noise: 1.0, anomaly_every: 0)
    gw = described_class.new
    sim.run(2000) { |hex| gw.ingest(hex) }
    rep = gw.report(1)
    expect(rep[:bytes_on_wire]).to be < rep[:bytes_uncompressed]
    expect(rep[:bandwidth_saved_pct]).to be > 0
  end

  it "detects injected anomalies end-to-end" do
    sim = EdgeSuite::DeviceSimulator.new(seed: 9, anomaly_every: 150, anomaly_size: 300)
    gw = described_class.new
    hits = 0
    sim.run(2000) { |hex| gw.ingest(hex) { hits += 1 } }
    expect(hits).to be > 0
    expect(gw.report(1)[:anomalies]).to eq(hits)
  end

  it "reports separately per channel" do
    gw = described_class.new
    gw.ingest(EdgeSuite::Frame.encode([1, 2, 3], channel: 1))
    gw.ingest(EdgeSuite::Frame.encode([4, 5, 6], channel: 2))
    expect(gw.report.map { |r| r[:channel] }).to contain_exactly(1, 2)
  end

  it "surfaces decode errors as exceptions to the caller" do
    gw = described_class.new
    expect { gw.ingest("deadbeef") }.to raise_error(EdgeSuite::DecodeError)
  end
end
