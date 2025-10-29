# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "semian"
require_relative "mock_service"
require_relative "experimental_resource"
require_relative "test_helpers"

# Oscillating errors test: 2% <-> 6% errors every 10 seconds
runner = Semian::Experiments::CircuitBreakerTestRunner.new(
  test_name: "Oscillating Errors Test",
  resource_name: "protected_service_oscillating_adaptive",
  degradation_phases: [Semian::Experiments::DegradationPhase.new(healthy: true)] * 2 +
                      [Semian::Experiments::DegradationPhase.new(error_rate: 0.02), Semian::Experiments::DegradationPhase.new(error_rate: 0.06)] * 9 +
                      [Semian::Experiments::DegradationPhase.new(healthy: true)] * 2,
  phase_duration: 10,
  semian_config: {
    adaptive_circuit_breaker: true,
    bulkhead: false,
  },
  graph_title: "Adaptive Circuit Breaker: Oscillating Errors (2% <-> 6%)",
  graph_filename: "oscillating_errors_adaptive.png",
  x_axis_label_interval: 60,
)

runner.run
