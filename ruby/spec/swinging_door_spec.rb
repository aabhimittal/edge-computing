# frozen_string_literal: true

require "spec_helper"

RSpec.describe EdgeSuite::SwingingDoor do
  # A deterministic random walk: the realistic case (temperature, pressure,
  # battery voltage) where most samples are redundant but the drift is real.
  def random_walk(n, seed: 7, step: 3.0)
    rng = Random.new(seed)
    value = 100.0
    (0...n).map do |i|
      value += rng.rand(-step..step)
      [i, value]
    end
  end

  it "never exceeds the configured deviation on a random walk" do
    series = random_walk(2000)
    [0.5, 2.0, 10.0].each do |dev|
      points = described_class.compress(series, deviation: dev)
      expect(described_class.max_error(series, points)).to be <= dev + 1e-9
    end
  end

  it "trades points for deviation monotonically" do
    series = random_walk(2000)
    counts = [0.5, 2.0, 10.0].map { |d| described_class.compress(series, deviation: d).length }
    expect(counts).to eq(counts.sort.reverse)
    expect(counts.last).to be < series.length / 10
  end

  it "keeps only the endpoints of a straight ramp" do
    series = (0..99).map { |i| [i, (3 * i) + 5.0] }
    points = described_class.compress(series, deviation: 0.0)
    expect(points.map { |p| [p.t, p.value] }).to eq([[0.0, 5.0], [99.0, 302.0]])
  end

  it "keeps only the endpoints of a flat signal" do
    series = (0..99).map { |i| [i, 42.0] }
    expect(described_class.compress(series, deviation: 0.0).length).to eq(2)
  end

  it "archives the corners of a step change" do
    series = (0..99).map { |i| [i, i < 50 ? 0.0 : 100.0] }
    points = described_class.compress(series, deviation: 0.5)
    expect(points.length).to be <= 5
    expect(described_class.max_error(series, points)).to be <= 0.5 + 1e-9
    # The transition is preserved, not smeared across the whole series.
    expect(points.map(&:t)).to include(49.0)
  end

  it "emits real samples, not synthesised ones, on a well-behaved signal" do
    series = (0..99).map { |i| [i, (i * 2).to_f] }
    points = described_class.compress(series, deviation: 1.0)
    originals = series.to_h
    points.each { |p| expect(p.value).to eq(originals[p.t.to_i]) }
  end

  it "honours a heartbeat on a signal that would otherwise stay silent" do
    series = (0..99).map { |i| [i, 7.0] }
    without = described_class.compress(series, deviation: 1.0)
    with = described_class.compress(series, deviation: 1.0, max_interval: 20)
    expect(without.length).to eq(2)
    expect(with.length).to be >= 5
    expect(described_class.max_error(series, with)).to eq(0.0)
  end

  it "streams: returns the point archived by each sample, nil otherwise" do
    door = described_class.new(deviation: 0.5)
    expect(door.update(0, 10.0)).to have_attributes(t: 0.0, value: 10.0)
    expect(door.update(1, 10.0)).to be_nil
    expect(door.update(2, 10.0)).to be_nil
    expect(door.update(3, 80.0)).to have_attributes(t: 2.0, value: 10.0)
    expect(door.flush).to have_attributes(t: 3.0, value: 80.0)
    expect(door.flush).to be_nil
    expect(door.seen).to eq(4)
    expect(door.emitted).to eq(3)
    expect(door.compression_ratio).to be_within(1e-9).of(0.75)
  end

  it "handles the degenerate series" do
    expect(described_class.compress([], deviation: 1.0)).to eq([])
    single = described_class.compress([[0, 5.0]], deviation: 1.0)
    expect(single.map(&:value)).to eq([5.0])
    expect(described_class.max_error([[0, 5.0]], single)).to eq(0.0)
  end

  it "reconstructs by interpolation and holds values outside the archive" do
    points = described_class.compress([[0, 0.0], [10, 10.0]], deviation: 0.0)
    expect(described_class.reconstruct(points, [-5, 0, 5, 10, 99]))
      .to eq([0.0, 0.0, 5.0, 10.0, 10.0])
    expect(described_class.reconstruct([], [1, 2])).to eq([0.0, 0.0])
  end

  it "rejects inputs that would silently corrupt the bound" do
    door = described_class.new(deviation: 1.0)
    door.update(5, 1.0)
    expect { door.update(5, 2.0) }.to raise_error(ArgumentError, /increase/)
    expect { door.update(4, 2.0) }.to raise_error(ArgumentError, /increase/)
    expect { door.update(6, Float::NAN) }.to raise_error(ArgumentError, /finite/)
    expect { door.update(Float::INFINITY, 1.0) }.to raise_error(ArgumentError, /finite/)
    expect { described_class.new(deviation: -1.0) }.to raise_error(ArgumentError)
    expect { described_class.new(max_interval: 0) }.to raise_error(ArgumentError)
  end

  it "survives extreme magnitudes and uneven sample spacing" do
    series = [[0, -1e6], [1, 1e6], [1000, -1e6], [1001, 0.0], [5000, 0.0]]
    points = described_class.compress(series, deviation: 100.0)
    expect(described_class.max_error(series, points)).to be <= 100.0 + 1e-6
  end

  it "reset returns the door to its initial state" do
    door = described_class.new(deviation: 1.0)
    door.update(0, 1.0)
    door.update(1, 1.0)
    door.reset
    expect(door.seen).to eq(0)
    expect(door.flush).to be_nil
    expect(door.update(0, 99.0)).to have_attributes(value: 99.0)
  end

  it "pairs with frame encoding: fewer points, fewer bytes on the wire" do
    series = random_walk(600, seed: 11, step: 0.4)
    dense = series.map { |_, v| v.round }
    points = described_class.compress(series, deviation: 1.0)
    sparse = points.map { |p| p.value.round }
    expect(EdgeSuite::Frame.encode(sparse).length)
      .to be < EdgeSuite::Frame.encode(dense).length / 4
  end
end
