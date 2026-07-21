# frozen_string_literal: true

require "spec_helper"
require "stringio"

RSpec.describe EdgeSuite::Transport do
  def hex(samples, **opts)
    EdgeSuite::Frame.encode(samples, **opts).map { |b| format("%02x", b) }.join
  end

  describe EdgeSuite::Transport::Stdin do
    it "yields non-empty frame lines from an IO" do
      io = StringIO.new("#{hex([1, 2, 3])}\n\n#{hex([4, 5, 6])}\n")
      frames = described_class.new(io).each_frame.to_a
      expect(frames.length).to eq(2)
      expect(EdgeSuite::Frame.decode([frames[0]].pack("H*").bytes).samples).to eq([1, 2, 3])
    end
  end

  describe EdgeSuite::Transport::Serial do
    it "reads hex frames from an injected IO without touching a real port" do
      io = StringIO.new("#{hex([10, 11, 12])}\n")
      collected = []
      described_class.new(device: "/dev/null", io: io).each_frame { |f| collected << f }
      expect(collected.length).to eq(1)
      expect(EdgeSuite::Frame.decode([collected[0]].pack("H*").bytes).samples).to eq([10, 11, 12])
    end

    it "does not attempt baud configuration when an IO is injected" do
      s = described_class.new(device: "/dev/null", io: StringIO.new(""), configure: true)
      expect(s).not_to receive(:system)
      s.each_frame { |_| }
    end
  end

  describe EdgeSuite::Transport::Mqtt do
    # Minimal stand-in for MQTT::Client: yields preset [topic, payload] messages.
    FakeMqttClient = Struct.new(:messages) do
      def subscribe(_topic); end

      def get
        messages.each { |topic, payload| yield topic, payload }
      end

      def disconnect; end
    end

    it "yields frame payloads (hex or binary) from the broker" do
      hex_payload = hex([7, 8, 9])
      bin_payload = EdgeSuite::Frame.encode([1, 2, 3]).pack("C*")
      client = FakeMqttClient.new([["edge/1/frames", "#{hex_payload}\n"],
                                   ["edge/2/frames", bin_payload]])
      out = described_class.new(client: client).each_frame.to_a
      expect(out.length).to eq(2)
      expect(EdgeSuite::Frame.decode([out[0]].pack("H*").bytes).samples).to eq([7, 8, 9])
      expect(EdgeSuite::Frame.decode(out[1]).samples).to eq([1, 2, 3])
    end

    it "raises a helpful error when the mqtt gem is missing and no client given" do
      t = described_class.new(host: "localhost")
      allow(t).to receive(:require).with("mqtt").and_raise(LoadError)
      expect { t.each_frame { |_| } }.to raise_error(LoadError, /gem install mqtt/)
    end
  end

  describe ".build" do
    it "returns Stdin by default" do
      expect(described_class.build(io: StringIO.new(""))).to be_a(EdgeSuite::Transport::Stdin)
    end

    it "returns Serial when :serial is given" do
      expect(described_class.build(serial: "/dev/ttyUSB0")).to be_a(EdgeSuite::Transport::Serial)
    end

    it "returns Mqtt when :mqtt is given" do
      expect(described_class.build(mqtt: "broker")).to be_a(EdgeSuite::Transport::Mqtt)
    end
  end
end
