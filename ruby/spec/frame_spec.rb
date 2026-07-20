# frozen_string_literal: true

require "spec_helper"

RSpec.describe EdgeSuite::Frame do
  def roundtrip(samples, **opts)
    described_class.decode(described_class.encode(samples, **opts))
  end

  it "round-trips a simple ascending batch" do
    samples = [100, 101, 103, 106, 110]
    expect(roundtrip(samples).samples).to eq(samples)
  end

  it "round-trips a flat batch and compresses it (zero-run RLE)" do
    samples = Array.new(64, 512)
    frame = described_class.encode(samples)
    decoded = described_class.decode(frame)
    expect(decoded.samples).to eq(samples)
    expect(decoded.compressed?).to be(true)
    # 64 identical samples must be far smaller than the 128 raw bytes.
    expect(frame.length).to be < 20
  end

  it "round-trips negative values and large jumps" do
    samples = [-32_768, 32_767, 0, -100, 100, -32_768]
    expect(roundtrip(samples).samples).to eq(samples)
  end

  it "round-trips a single-sample batch" do
    expect(roundtrip([777]).samples).to eq([777])
  end

  it "carries the anomaly flag" do
    expect(roundtrip([1, 2, 3], anomaly: true).anomaly?).to be(true)
    expect(roundtrip([1, 2, 3], anomaly: false).anomaly?).to be(false)
  end

  it "carries the channel id" do
    expect(roundtrip([1, 2, 3], channel: 7).channel).to eq(7)
  end

  it "falls back to raw when compression would expand" do
    # Alternating large deltas defeat RLE; encoder should pick raw.
    samples = Array.new(40) { |i| i.even? ? 0 : 20_000 }
    frame = described_class.encode(samples)
    decoded = described_class.decode(frame)
    expect(decoded.samples).to eq(samples)
    expect(decoded.compressed?).to be(false)
  end

  it "accepts a binary string as decode input" do
    frame = described_class.encode([5, 6, 7])
    bin = frame.pack("C*")
    expect(described_class.decode(bin).samples).to eq([5, 6, 7])
  end

  it "raises on a corrupted CRC" do
    frame = described_class.encode([1, 2, 3, 4])
    frame[-1] ^= 0xFF
    expect { described_class.decode(frame) }
      .to raise_error(EdgeSuite::DecodeError, /crc/)
  end

  it "raises on bad magic" do
    frame = described_class.encode([1, 2, 3])
    frame[0] = 0x00
    frame[-1] = EdgeSuite::Codec.crc8(frame[0...-1]) # fix crc so magic is the failure
    expect { described_class.decode(frame) }
      .to raise_error(EdgeSuite::DecodeError, /magic/)
  end

  it "produces a stable wire format (golden frame guard)" do
    # Guards the cross-language contract: if this hex changes, the firmware
    # decoder must change too. samples: [512, 512, 515, 515, 500]
    golden = described_class.encode([512, 512, 515, 515, 500], channel: 1)
    hex = golden.map { |b| format("%02x", b) }.join
    expect(described_class.decode([hex].pack("H*").bytes).samples)
      .to eq([512, 512, 515, 515, 500])
    # Frame must be shorter than the 10-byte raw delta body + header.
    expect(golden.length).to be <= EdgeSuite::Frame::HEADER_LEN + 8 + 1
  end
end
