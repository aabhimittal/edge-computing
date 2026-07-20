# frozen_string_literal: true

require "spec_helper"

RSpec.describe EdgeSuite::AdaptiveSampler do
  it "relaxes toward max_interval on a quiet signal" do
    s = described_class.new(min_interval: 50, max_interval: 2000)
    interval = nil
    100.times { interval = s.update(500) }
    expect(interval).to be_within(1).of(2000)
  end

  it "tightens toward min_interval on a highly active signal" do
    s = described_class.new(min_interval: 50, max_interval: 2000, ref_range: 50.0)
    interval = nil
    100.times { |i| interval = s.update(i.even? ? 0 : 1000) }
    expect(interval).to eq(50)
  end

  it "forces min_interval when an anomaly is signalled" do
    s = described_class.new(min_interval: 50, max_interval: 2000)
    50.times { s.update(500) } # quiet -> would otherwise be ~2000
    expect(s.update(500, anomaly: true)).to eq(50)
  end

  it "keeps the interval within [min, max]" do
    s = described_class.new(min_interval: 100, max_interval: 900)
    rng = Random.new(3)
    100.times do
      i = s.update(rng.rand(0..1023))
      expect(i).to be_between(100, 900)
    end
  end
end
