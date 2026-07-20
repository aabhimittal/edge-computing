# frozen_string_literal: true

require_relative "lib/edge_suite/version"

Gem::Specification.new do |spec|
  spec.name = "edge_suite"
  spec.version = EdgeSuite::VERSION
  spec.authors = ["edge-computing contributors"]
  spec.summary = "Edge-computing gateway: decode, analyze, and coordinate EdgeSuite device frames."
  spec.description = <<~DESC
    Ruby companion to the EdgeSuite Arduino library. Decodes the delta+RLE frame
    format produced on-device, runs the same streaming anomaly detection and
    adaptive-sampling models server-side, and coordinates a fleet of edge nodes
    with bandwidth accounting and retuning recommendations. Ships a hardware-free
    device simulator so the full pipeline runs on any machine.
  DESC
  spec.homepage = "https://github.com/aabhimittal/edge-computing"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0"

  spec.files = Dir[
    "lib/**/*.rb",
    "bin/*",
    "examples/*.rb",
    "README.md"
  ]
  spec.bindir = "bin"
  spec.executables = %w[edge-gateway edge-sim]
  spec.require_paths = ["lib"]

  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rspec", "~> 3.0"
end
