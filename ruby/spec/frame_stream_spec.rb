# frozen_string_literal: true

require "spec_helper"

RSpec.describe EdgeSuite::FrameStream do
  def frame(samples, channel: 1)
    EdgeSuite::Frame.encode(samples, channel: channel)
  end

  let(:a) { frame([100, 101, 103, 106, 110]) }
  let(:b) { frame(Array.new(40, 512), channel: 2) }
  let(:raw) { frame(Array.new(20) { |i| i.even? ? -20_000 : 20_000 }, channel: 3) }

  it "measures a frame from its own header, compressed or raw" do
    expect(EdgeSuite::Frame.frame_length(a)).to eq(a.length)
    expect(EdgeSuite::Frame.frame_length(b)).to eq(b.length)
    expect(EdgeSuite::Frame.frame_length(raw)).to eq(raw.length)
    # Offset form: the frame does not have to start at zero.
    expect(EdgeSuite::Frame.frame_length([0, 0] + a, 2)).to eq(a.length)
    # Smallest possible frame: one sample, empty body.
    tiny = frame([7])
    expect(tiny.length).to eq(EdgeSuite::Frame::HEADER_LEN + 1)
    expect(EdgeSuite::Frame.frame_length(tiny)).to eq(tiny.length)
  end

  it "signals 'need more bytes' apart from 'this is garbage'" do
    expect { EdgeSuite::Frame.frame_length(a[0..4]) }
      .to raise_error(EdgeSuite::IncompleteFrame)
    expect { EdgeSuite::Frame.frame_length(a[0...-2]) }
      .to raise_error(EdgeSuite::IncompleteFrame)
    expect { EdgeSuite::Frame.frame_length([0x45, 0x53, 9, 1, 0, 1, 0, 0, 0, 0]) }
      .to raise_error(EdgeSuite::DecodeError, /version/)
    expect { EdgeSuite::Frame.frame_length([0x45, 0x53, 1, 1, 0, 0, 0, 0, 0, 0]) }
      .to raise_error(EdgeSuite::DecodeError, /zero sample count/)
  end

  it "reassembles frames split across arbitrary chunk boundaries" do
    stream = described_class.new
    bytes = a + b + raw
    got = []
    bytes.each_slice(3) { |chunk| got.concat(stream.feed(chunk)) }
    expect(got).to eq([a, b, raw])
    expect(stream.pending).to eq(0)
  end

  it "handles back-to-back minimal frames" do
    tiny = [frame([7]), frame([-1], channel: 9), frame([32_767])]
    expect(described_class.new.feed(tiny.flatten)).to eq(tiny)
  end

  it "reassembles a stream fed one byte at a time" do
    stream = described_class.new
    got = (a + b).map { |byte| stream.feed(byte) }.flatten(1)
    expect(got).to eq([a, b])
  end

  it "skips leading and trailing line noise" do
    stream = described_class.new
    got = stream.feed([0xFF, 0x00, 0x13] + a + [0x7E, 0x7E])
    expect(got).to eq([a])
    expect(stream.stats[:dropped_bytes]).to eq(5)
    expect(stream.stats[:frames]).to eq(1)
  end

  it "recovers the next frame after a corrupted one" do
    corrupt = a.dup
    corrupt[10] ^= 0xFF # break the body, so the CRC no longer matches
    stream = described_class.new
    got = stream.feed(corrupt + b)
    expect(got).to eq([b])
    expect(stream.stats[:crc_errors]).to eq(1)
    expect(stream.stats[:resyncs]).to be >= 1
  end

  it "recovers when a frame is truncated mid-stream" do
    stream = described_class.new
    got = stream.feed(a[0...-3] + b)
    expect(got).to eq([b])
  end

  it "steps one byte past a false magic instead of skipping the whole window" do
    stream = described_class.new
    # 'E' 'S' with an unusable version byte, immediately followed by a real frame.
    got = stream.feed([0x45, 0x53, 0x09] + a)
    expect(got).to eq([a])
    expect(stream.stats[:resyncs]).to eq(1)
  end

  it "finds a frame whose magic overlaps a false one" do
    stream = described_class.new
    expect(stream.feed([0x45] + a)).to eq([a])
  end

  it "holds a lone trailing magic byte until its partner arrives" do
    stream = described_class.new
    expect(stream.feed([0x45])).to be_empty
    expect(stream.pending).to eq(1)
    expect(stream.feed(a[1..])).to eq([a])
  end

  it "refuses a header that claims an implausibly large frame" do
    stream = described_class.new(max_frame: 128)
    # count = 5000 raw samples would be ~10 kB: a corrupt length, not a frame.
    bogus = [0x45, 0x53, 1, 1, 0, 0x88, 0x13, 0, 0]
    got = stream.feed(bogus + a)
    expect(got).to eq([a])
    expect(stream.stats[:resyncs]).to be >= 1
  end

  it "bounds the buffer when the link never completes a frame" do
    stream = described_class.new(max_frame: 512, max_buffer: 512)
    # A header promising 250 raw samples (508 bytes) that never arrive.
    stream.feed([0x45, 0x53, 1, 1, 0, 250, 0, 0, 0] + Array.new(400, 0x11))
    expect(stream.stats[:overflows]).to eq(0)
    stream.feed(Array.new(200, 0x11))
    expect(stream.stats[:overflows]).to eq(1)
    expect(stream.pending).to be <= 512
    # ...and the stream is still usable afterwards.
    expect(stream.feed(a)).to eq([a])
  end

  it "rejects a zero-length run rather than scanning forever" do
    # Hand-built compressed body: token 0 (run) followed by run length 0.
    header = [0x45, 0x53, 1, 1, EdgeSuite::Frame::FLAG_COMPRESSED, 4, 0, 0, 0]
    expect { EdgeSuite::Frame.frame_length(header + [0, 0, 0, 0, 0, 0]) }
      .to raise_error(EdgeSuite::DecodeError, /zero-length run/)
  end

  it "exposes a one-shot scan over a captured dump" do
    frames, stats = described_class.scan([0xAA] + a + [0xBB] + b)
    expect(frames).to eq([a, b])
    expect(stats[:frames]).to eq(2)
    expect(stats[:dropped_bytes]).to eq(2)
  end

  it "accepts binary strings and feeds the gateway directly" do
    stream = described_class.new
    gw = EdgeSuite::Gateway.new
    samples = 0
    stream.feed((a + b).pack("C*")) { |f| samples += gw.ingest(f)[:samples] }
    expect(samples).to eq(45)
  end

  it "validates its own configuration" do
    expect { described_class.new(max_frame: 4) }.to raise_error(ArgumentError)
    expect { described_class.new(max_frame: 512, max_buffer: 128) }
      .to raise_error(ArgumentError)
    expect { described_class.new.feed(:nope) }.to raise_error(ArgumentError)
  end
end
