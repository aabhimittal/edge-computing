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

puts "\nSwingingDoor — points kept, and the error that buys (2000 samples)\n\n"

def door_profile(name, series, deviation)
  points = EdgeSuite::SwingingDoor.compress(series, deviation: deviation)
  error = EdgeSuite::SwingingDoor.max_error(series, points)
  puts format("%-22s  dev %5.1f  kept %5d/%d (%4.1f%%)  worst error %.3f",
              name, deviation, points.length, series.length,
              100.0 * points.length / series.length, error)
end

walk_rng = Random.new(7)
walk_value = 100.0
walk = Array.new(2000) { |t| [t, walk_value += walk_rng.rand(-3.0..3.0)] }
ramp = Array.new(2000) { |t| [t, (3 * t) + 5.0] }
flat = Array.new(2000) { |t| [t, 42.0] }

door_profile("straight ramp", ramp, 0.0)
door_profile("flat (constant)", flat, 0.0)
[0.5, 2.0, 10.0].each { |d| door_profile("random walk", walk, d) }

# The end-to-end story: the door and the codec compose, and the frames the
# gateway receives are what the two together produce.
kept = EdgeSuite::SwingingDoor.compress(walk, deviation: 2.0).map { |p| p.value.round }
dense = walk.map { |_t, v| v.round }
dense_bytes = dense.each_slice(32).sum { |b| EdgeSuite::Frame.encode(b).length }
kept_bytes = kept.each_slice(32).sum { |b| EdgeSuite::Frame.encode(b).length }
puts format("\ncombined (walk, dev 2.0): %d B -> %d B on the wire (%.1fx)",
            dense_bytes, kept_bytes, dense_bytes.to_f / kept_bytes)
