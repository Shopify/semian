# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "semian"
require_relative "mock_service"
require_relative "experimental_resource"
require_relative "test_helpers"

# Sudden error spike test: 1% -> 100% -> 1%
runner = Semian::Experiments::CircuitBreakerTestRunner.new(
  test_name: "Sudden Error Spike Test (Classic) - 100% for 20 seconds",
  resource_name: "protected_service_sudden_error_spike_100",
  degradation_phases: [Semian::Experiments::DegradationPhase.new(error_rate: 0.01)] * 3 +
                      [Semian::Experiments::DegradationPhase.new(error_rate: 1.00)] +
                      [Semian::Experiments::DegradationPhase.new(error_rate: 0.01)] * 3,
  phase_duration: 20,
  semian_config: {
    success_threshold: 2,
    error_threshold: 3,
    error_threshold_timeout: 20,
    error_timeout: 15,
    bulkhead: false,
  },
  graph_title: "Sudden Error Spike Test (Classic) - 100% for 20 seconds",
  graph_filename: "sudden_error_spike_100.png",
  x_axis_label_interval: 60,
)

runner.run
