# frozen_string_literal: true

# End-to-end demo without hardware: a simulated edge node streams frames into a
# gateway, which decodes them, detects anomalies, and reports bandwidth savings.
#
#   ruby examples/run_demo.rb

require_relative "../lib/edge_suite"

sim = EdgeSuite::DeviceSimulator.new(seed: 7, anomaly_every: 300)
gateway = EdgeSuite::Gateway.new

alerts = 0
sim.run(3000) do |hex|
  gateway.ingest(hex) do |ch, idx, value, score|
    alerts += 1
    puts format("anomaly  ch=%d idx=%-4d value=%-6d z=%+.2f", ch, idx, value, score)
  end
end

puts "\ndetected #{alerts} anomalies\n\n"
gateway.report.each do |r|
  puts "channel #{r[:channel]}"
  puts "  frames ............. #{r[:frames]}"
  puts "  samples ............ #{r[:samples]}"
  puts "  on wire ............ #{r[:bytes_on_wire]} B"
  puts "  uncompressed ....... #{r[:bytes_uncompressed]} B"
  puts "  compression ratio .. #{r[:compression_ratio]}"
  puts "  bandwidth saved .... #{r[:bandwidth_saved_pct]}%"
  puts "  signal mean/std .... #{r[:mean]} / #{r[:std]}"
  puts "  advice ............. #{r[:recommendation]}"
end
