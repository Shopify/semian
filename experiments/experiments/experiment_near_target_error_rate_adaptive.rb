# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))

require "semian"
require_relative "../mock_service"
require_relative "../experimental_resource"
require_relative "../experiment_helpers"

runner = Semian::Experiments::CircuitBreakerExperimentRunner.new(
  experiment_name: "Near Target Error Rate Experiment (Adaptive)",
  resource_name: "protected_service_near_target_adaptive",
  degradation_phases: [Semian::Experiments::DegradationPhase.new(healthy: true)] * 1 +
                      [Semian::Experiments::DegradationPhase.new(error_rate: 0.012)] * 4 +
                      [Semian::Experiments::DegradationPhase.new(healthy: true)] * 1,
  phase_duration: 30,
  semian_config: {
    adaptive_circuit_breaker: true,
    bulkhead: false,
  },
  graph_title: "Adaptive Circuit Breaker: Near Target Error Rate (1.2%)",
  graph_filename: "near_target_error_rate_adaptive.png",
  x_axis_label_interval: 30,
  graph_bucket_size: 1,
)

runner.run
