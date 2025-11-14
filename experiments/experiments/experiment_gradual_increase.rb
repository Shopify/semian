# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))

require "semian"
require_relative "../mock_service"
require_relative "../experimental_resource"
require_relative "../experiment_helpers"

# Gradual error increase experiment: 1% -> 1.5% -> 2% -> ... -> 5% -> 1%
runner = Semian::Experiments::CircuitBreakerExperimentRunner.new(
  experiment_name: "Gradual Error Increase Experiment",
  resource_name: "protected_service_gradual",
  degradation_phases: [
    Semian::Experiments::DegradationPhase.new(healthy: true),
    Semian::Experiments::DegradationPhase.new(error_rate: 0.015),
    Semian::Experiments::DegradationPhase.new(error_rate: 0.02),
    Semian::Experiments::DegradationPhase.new(error_rate: 0.025),
    Semian::Experiments::DegradationPhase.new(error_rate: 0.03),
    Semian::Experiments::DegradationPhase.new(error_rate: 0.035),
    Semian::Experiments::DegradationPhase.new(error_rate: 0.04),
    Semian::Experiments::DegradationPhase.new(error_rate: 0.045),
    Semian::Experiments::DegradationPhase.new(error_rate: 0.05),
    Semian::Experiments::DegradationPhase.new(healthy: true),
  ],
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
