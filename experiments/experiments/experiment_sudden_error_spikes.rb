# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))

require "semian"
require_relative "../mock_service"
require_relative "../experimental_resource"
require_relative "../experiment_helpers"

# Error spikes experiment:
# Phase 1: 1% for 60 seconds
# Phase 2: 20% for 20 seconds
# Phase 3: 1% for 60 seconds
# Phase 4: 60% for 20 seconds
# Phase 5: 1% for 60 seconds
# Phase 6: 100% for 20 seconds
# Phase 7: 1% for 60 seconds
runner = Semian::Experiments::CircuitBreakerExperimentRunner.new(
  experiment_name: "Sudden Error Spikes Experiment (Classic)",
  resource_name: "protected_service_sudden_error_spikes",
  degradation_phases: [Semian::Experiments::DegradationPhase.new(healthy: true)] * 3 +
                      [Semian::Experiments::DegradationPhase.new(error_rate: 0.20)] +
                      [Semian::Experiments::DegradationPhase.new(healthy: true)] * 3 +
                      [Semian::Experiments::DegradationPhase.new(error_rate: 0.60)] +
                      [Semian::Experiments::DegradationPhase.new(healthy: true)] * 3 +
                      [Semian::Experiments::DegradationPhase.new(error_rate: 1.00)] +
                      [Semian::Experiments::DegradationPhase.new(healthy: true)] * 3,
  phase_duration: 20,
  semian_config: {
    success_threshold: 2,
    error_threshold: 12,
    error_threshold_timeout: 20,
    error_timeout: 15,
    bulkhead: false,
  },
  graph_title: "Classic: Sudden Error Spikes, 20 second spikes (20%, 60%, 100%)",
  graph_filename: "sudden_error_spikes.png",
  x_axis_label_interval: 60,
)

runner.run
