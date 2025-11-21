# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))

require "semian"
require_relative "../mock_service"
require_relative "../experimental_resource"
require_relative "../experiment_helpers"

runner = Semian::Experiments::CircuitBreakerExperimentRunner.new(
  experiment_name: "Near Target Error Rate Experiment (Classic)",
  resource_name: "protected_service_near_target",
  degradation_phases: [Semian::Experiments::DegradationPhase.new(healthy: true)] * 1 +
                      [Semian::Experiments::DegradationPhase.new(error_rate: 0.012)] * 4 +
                      [Semian::Experiments::DegradationPhase.new(healthy: true)] * 1,
  phase_duration: 30,
  semian_config: {
    success_threshold: 2,
    error_threshold: 3,
    error_threshold_timeout: 20,
    error_timeout: 15,
    bulkhead: false,
  },
  graph_title: "Classic Circuit Breaker: Near Target Error Rate (1.2%)",
  graph_filename: "near_target_error_rate.png",
  x_axis_label_interval: 30,
)

runner.run
