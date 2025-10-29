# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "semian"
require_relative "mock_service"
require_relative "experimental_resource"
require_relative "test_helpers"

# Sustained load test: 120s baseline (1%) -> 300s sustained (20%) -> 120s recovery (1%)
runner = Semian::Experiments::CircuitBreakerTestRunner.new(
  test_name: "Sustained Load Test",
  resource_name: "protected_service",
  degradation_phases: [Semian::Experiments::DegradationPhase.new(healthy: true)] * 4 +
                      [Semian::Experiments::DegradationPhase.new(error_rate: 0.20)] * 10 +
                      [Semian::Experiments::DegradationPhase.new(healthy: true)] * 4,
  phase_duration: 30,
  semian_config: {
    success_threshold: 2,
    error_threshold: 3,
    error_threshold_timeout: 20,
    error_timeout: 15,
    bulkhead: false,
  },
  graph_title: "Classic Circuit Breaker: Sustained 20% Error Load",
  graph_filename: "sustained_load.png",
  x_axis_label_interval: 30,
)

runner.run
