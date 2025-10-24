# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "semian"
require_relative "mock_service"
require_relative "experimental_resource"
require_relative "test_helpers"

# Gradual error increase test: 1% -> 1.5% -> 2% -> ... -> 5% -> 1%
runner = Semian::Experiments::CircuitBreakerTestRunner.new(
  test_name: "Gradual Error Increase Test",
  resource_name: "protected_service_gradual",
  error_phases: [0.01, 0.015, 0.02, 0.025, 0.03, 0.035, 0.04, 0.045, 0.05, 0.01],
  phase_duration: 60,
  semian_config: {
    success_threshold: 2,
    error_threshold: 3,
    error_threshold_timeout: 20,
    error_timeout: 15,
    bulkhead: false,
  },
  graph_title: "Classic Circuit Breaker: Gradual Error Increase (1% to 5%)",
  graph_filename: "gradual_increase.png",
  x_axis_label_interval: 60,
)

runner.run
