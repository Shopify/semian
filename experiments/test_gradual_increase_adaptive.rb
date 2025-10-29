# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "semian"
require_relative "mock_service"
require_relative "experimental_resource"
require_relative "test_helpers"

# Gradual error increase test: 1% -> 1.5% -> 2% -> ... -> 5% -> 1%
runner = Semian::Experiments::CircuitBreakerTestRunner.new(
  test_name: "Gradual Error Increase Test",
  resource_name: "protected_service_gradual_adaptive",
  degradation_phases: [
    Semian::Experiments::DegradationPhase.new(error_rate: 0.01),
    Semian::Experiments::DegradationPhase.new(error_rate: 0.015),
    Semian::Experiments::DegradationPhase.new(error_rate: 0.02),
    Semian::Experiments::DegradationPhase.new(error_rate: 0.025),
    Semian::Experiments::DegradationPhase.new(error_rate: 0.03),
    Semian::Experiments::DegradationPhase.new(error_rate: 0.035),
    Semian::Experiments::DegradationPhase.new(error_rate: 0.04),
    Semian::Experiments::DegradationPhase.new(error_rate: 0.045),
    Semian::Experiments::DegradationPhase.new(error_rate: 0.05),
    Semian::Experiments::DegradationPhase.new(error_rate: 0.01),
  ],
  phase_duration: 60,
  semian_config: {
    adaptive_circuit_breaker: true,
    bulkhead: false,
  },
  graph_title: "Adaptive Circuit Breaker: Gradual Error Increase (1% to 5%)",
  graph_filename: "gradual_increase_adaptive.png",
  x_axis_label_interval: 60,
)

runner.run
