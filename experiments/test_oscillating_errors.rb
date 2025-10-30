# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "semian"
require_relative "mock_service"
require_relative "experimental_resource"
require_relative "test_helpers"

# Oscillating errors test: 2% <-> 6% errors every 10 seconds
runner = Semian::Experiments::CircuitBreakerTestRunner.new(
  test_name: "Oscillating Errors Test",
  resource_name: "protected_service_oscillating",
  error_phases: [0.01, 0.01] + [0.02, 0.06] * 9 + [0.01, 0.01],
  phase_duration: 10,
  semian_config: {
    success_threshold: 2,
    error_threshold: 30,
    error_threshold_timeout: 20,
    error_timeout: 15,
    bulkhead: false,
  },
  graph_title: "Classic Circuit Breaker: Oscillating Errors (2% <-> 6%)",
  graph_filename: "oscillating_errors.png",
  x_axis_label_interval: 60,
)

runner.run
