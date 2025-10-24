# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "semian"
require_relative "mock_service"
require_relative "experimental_resource"
require_relative "test_helpers"

timestamp = Time.now.strftime("%Y%m%d_%H%M%S")

# Error spikes test: 0.1% -> 20% -> 0.1% -> 60% -> 0.1% with 20 second spikes
runner = Semian::Experiments::CircuitBreakerTestRunner.new(
  test_name: "Sudden Error Spikes Test - adaptive",
  resource_name: "protected_service_sudden_error_spikes_adaptive",
  error_phases: [0.01] * 3 + [0.20] + [0.01] * 3 + [0.60] + [0.01] * 3,
  phase_duration: 20,
  semian_config: {
    adaptive_circuit_breaker: true,
    bulkhead: false,
  },
  graph_title: "Adaptive: Sudden Error Spikes, 20 second spikes (0.1% -> 20% -> 0.1% -> 60% -> 0.1%)",
  graph_filename: "sudden_error_spikes_adaptive_#{timestamp}.png",
  x_axis_label_interval: 60,
)

runner.run
