# frozen_string_literal: true

require "spec_helper"

RSpec.describe EdgeSuite::Codec do
  describe "varint" do
    it "round-trips a range of unsigned values" do
      [0, 1, 127, 128, 300, 16_383, 16_384, 2_097_151, 0xFFFFFFFF].each do |v|
        bytes = described_class.put_varint([], v)
        out, pos = described_class.get_varint(bytes, 0)
        expect(out).to eq(v)
        expect(pos).to eq(bytes.length)
      end
    end

    it "uses 1 byte for values < 128 and 2 bytes up to 16383" do
      expect(described_class.put_varint([], 127).length).to eq(1)
      expect(described_class.put_varint([], 128).length).to eq(2)
      expect(described_class.put_varint([], 16_383).length).to eq(2)
      expect(described_class.put_varint([], 16_384).length).to eq(3)
    end

    it "raises on a truncated varint" do
      expect { described_class.get_varint([0x80], 0) }
        .to raise_error(EdgeSuite::DecodeError)
    end
  end

  describe "zigzag" do
    it "round-trips signed values including boundaries" do
      [0, -1, 1, -2, 2, 32_767, -32_768, 65_535, -65_535, 2_147_483_647,
       -2_147_483_648].each do |v|
        expect(described_class.zigzag_decode(described_class.zigzag_encode(v))).to eq(v)
      end
    end

    it "maps small magnitudes to small unsigned numbers" do
      expect(described_class.zigzag_encode(0)).to eq(0)
      expect(described_class.zigzag_encode(-1)).to eq(1)
      expect(described_class.zigzag_encode(1)).to eq(2)
      expect(described_class.zigzag_encode(-2)).to eq(3)
    end
  end

  describe "crc8" do
    it "matches the CRC-8/SMBUS check value for '123456789'" do
      # Standard check vector for CRC-8/SMBUS (poly 0x07, init 0x00) is 0xF4.
      expect(described_class.crc8("123456789".bytes)).to eq(0xF4)
    end

    it "detects a single-bit change" do
      a = described_class.crc8([1, 2, 3, 4])
      b = described_class.crc8([1, 2, 3, 5])
      expect(a).not_to eq(b)
    end
  end
end
