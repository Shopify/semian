# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))

require "semian"
require_relative "../mock_service"
require_relative "../experimental_resource"
require_relative "../experiment_helpers"

# Sustained load experiment: 120s baseline (1%) -> 300s sustained (20%) -> 120s recovery (1%)
runner = Semian::Experiments::CircuitBreakerExperimentRunner.new(
  experiment_name: "Sustained Load Experiment (Adaptive)",
  resource_name: "protected_service_sustained_load_adaptive",
  degradation_phases: [Semian::Experiments::DegradationPhase.new(healthy: true)] * 4 +
                      [Semian::Experiments::DegradationPhase.new(error_rate: 0.20)] * 10 +
                      [Semian::Experiments::DegradationPhase.new(healthy: true)] * 4,
  phase_duration: 30,
  semian_config: {
    adaptive_circuit_breaker: true,
    bulkhead: false,
  },
  graph_title: "Adaptive Circuit Breaker: Sustained 20% Error Load",
  graph_filename: "sustained_load_adaptive.png",
  x_axis_label_interval: 30,
)

runner.run
