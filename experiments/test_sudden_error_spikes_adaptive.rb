# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "semian"
require_relative "mock_service"
require_relative "experimental_resource"
require_relative "test_helpers"

# Error spikes test:
# Phase 1: 1% for 60 seconds
# Phase 2: 20% for 20 seconds
# Phase 3: 1% for 60 seconds
# Phase 4: 60% for 20 seconds
# Phase 5: 1% for 60 seconds
# Phase 6: 100% for 20 seconds
# Phase 7: 1% for 60 seconds
runner = Semian::Experiments::CircuitBreakerTestRunner.new(
  test_name: "Sudden Error Spikes Test - adaptive",
  resource_name: "protected_service_sudden_error_spikes_adaptive",
  error_phases: [0.01] * 3 + [0.20] + [0.01] * 3 + [0.60] + [0.01] * 3 + [1.00] + [0.01] * 3,
  phase_duration: 20,
  semian_config: {
    adaptive_circuit_breaker: true,
    bulkhead: false,
  },
  graph_title: "Adaptive: Sudden Error Spikes, 20 second spikes (20%, 60%, 100%)",
  graph_filename: "sudden_error_spikes_adaptive.png",
  x_axis_label_interval: 60,
)

runner.run
