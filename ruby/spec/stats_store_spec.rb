# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe EdgeSuite::StatsStore do
  around do |ex|
    Dir.mktmpdir { |dir| @dir = dir; ex.run }
  end

  it "appends anomaly events and counts them" do
    store = described_class.new(dir: @dir)
    store.record_anomaly(channel: 1, index: 3, value: 900, score: 12.5, ts: "2026-01-01T00:00:00Z")
    store.record_anomaly(channel: 1, index: 7, value: 20, score: -9.1, ts: "2026-01-01T00:00:01Z")
    store.close
    expect(store.anomaly_count).to eq(2)
    events = described_class.new(dir: @dir).each_anomaly.to_a
    expect(events.first[:channel]).to eq(1)
    expect(events.first[:score]).to eq(12.5)
    expect(events.last[:value]).to eq(20)
  end

  it "writes and reloads an atomic snapshot" do
    store = described_class.new(dir: @dir)
    reports = [{ channel: 1, frames: 4, samples: 128, bandwidth_saved_pct: 31.9 }]
    store.write_snapshot(reports, ts: "2026-01-01T00:00:00Z")
    loaded = described_class.new(dir: @dir).load_snapshot
    expect(loaded[:updated_at]).to eq("2026-01-01T00:00:00Z")
    expect(loaded[:channels].first[:channel]).to eq(1)
    expect(loaded[:channels].first[:bandwidth_saved_pct]).to eq(31.9)
  end

  it "leaves no temp file behind after a snapshot" do
    store = described_class.new(dir: @dir)
    store.write_snapshot([{ channel: 1 }])
    expect(Dir.children(@dir)).to include("snapshot.json")
    expect(Dir.children(@dir).any? { |f| f.end_with?(".tmp") }).to be(false)
  end

  it "returns nil snapshot before anything is written" do
    expect(described_class.new(dir: @dir).load_snapshot).to be_nil
  end

  it "persists anomalies across store instances (resume)" do
    s1 = described_class.new(dir: @dir)
    s1.record_anomaly(channel: 2, index: 1, value: 5, score: 4.0)
    s1.close
    s2 = described_class.new(dir: @dir)
    s2.record_anomaly(channel: 2, index: 2, value: 6, score: 5.0)
    s2.close
    expect(described_class.new(dir: @dir).anomaly_count).to eq(2)
  end
end
