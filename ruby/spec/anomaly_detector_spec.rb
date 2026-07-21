# frozen_string_literal: true

require "spec_helper"

RSpec.describe EdgeSuite::AnomalyDetector do
  it "does not flag a steady noisy signal after warmup" do
    det = described_class.new(warmup: 20)
    rng = Random.new(1)
    flags = (0...500).map { det.update(100 + rng.rand(-2..2)) }
    # Allow a tiny rate of statistical false positives, but not many.
    expect(flags.count(true)).to be <= 3
  end

  it "flags a large injected spike" do
    det = described_class.new(warmup: 20, threshold: 3.5)
    50.times { det.update(100 + rand(-1..1)) }
    expect(det.update(100_00)).to be(true)
  end

  it "stays silent during warmup even on a spike" do
    det = described_class.new(warmup: 20)
    det.update(100)
    expect(det.update(9999)).to be(false)
  end

  it "reports a running mean near the signal level" do
    det = described_class.new
    200.times { det.update(250) }
    expect(det.mean).to be_within(1.0).of(250)
  end
end
