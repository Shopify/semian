# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "semian"
require_relative "mock_service"
require_relative "experimental_resource"
require_relative "test_helpers"

# Sudden error spike test: 1% -> 100% -> 1%
runner = Semian::Experiments::CircuitBreakerTestRunner.new(
  test_name: "Sudden Error Spike Test (Adaptive) - 100% for 20 seconds",
  resource_name: "protected_service_sudden_error_spike_100_adaptive",
  error_phases: [0.01] + [0.30] + [0.01],
  phase_duration: 20,
  semian_config: {
    adaptive_circuit_breaker: true,
    bulkhead: false,
  },
  graph_title: "Sudden Error Spike Test (Adaptive) - 30% for 20 seconds",
  graph_filename: "sudden_error_spike_100_adaptive.png",
  x_axis_label_interval: 60,
)

runner.run
