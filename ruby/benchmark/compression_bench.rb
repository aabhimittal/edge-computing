# frozen_string_literal: true

# Measures the compression ratio of the frame codec across signal profiles,
# so the bandwidth story in the README stays honest and reproducible.
#
#   ruby benchmark/compression_bench.rb

require_relative "../lib/edge_suite"

def gaussian(rng, sigma)
  u1 = 1.0 - rng.rand
  u2 = 1.0 - rng.rand
  Math.sqrt(-2.0 * Math.log(u1)) * Math.cos(2 * Math::PI * u2) * sigma
end

def profile(name, n: 2000, seed: 42)
  rng = Random.new(seed)
  samples = Array.new(n) { |t| yield(t, rng) }
  # Encode in batches of 32 the way a device would.
  wire = 0
  samples.each_slice(32) { |batch| wire += EdgeSuite::Frame.encode(batch).length }
  raw = samples.length * 2
  ratio = wire.to_f / raw
  puts format("%-22s  raw %6d B  wire %6d B  ratio %.3f  saved %5.1f%%",
              name, raw, wire, ratio, (1 - ratio) * 100)
end

puts "EdgeSuite frame codec — compression by signal profile (batch=32)\n\n"

profile("flat (constant)") { |_t, _r| 512 }
profile("slow sine") { |t, _r| (512 + 40 * Math.sin(2 * Math::PI * t / 200)).round }
profile("sine + light noise") { |t, r| (512 + 40 * Math.sin(t / 30.0) + gaussian(r, 2)).round }
profile("noisy") { |_t, r| (512 + gaussian(r, 30)).round }
profile("random walk") do
  # closure-local accumulator via instance var on the block's binding
  @walk = (@walk || 512) + rand(-3..3)
  @walk
end
profile("full-scale random") { |_t, r| r.rand(0..1023) }
