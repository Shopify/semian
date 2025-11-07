# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))

require "semian"
require_relative "../mock_service"
require_relative "../experimental_resource"
require_relative "../experiment_helpers"

# Lower bound windup experiment: demonstrates the response to error spikes
# when integral has accumulated negative values during extended low-error periods.
runner = Semian::Experiments::CircuitBreakerExperimentRunner.new(
  experiment_name: "Lower Bound Windup Experiment",
  resource_name: "protected_service_windup_demo",
  degradation_phases: [Semian::Experiments::DegradationPhase.new(error_rate: 0.01)] +
                      [Semian::Experiments::DegradationPhase.new(error_rate: 0.60)] * 6 +
                      [Semian::Experiments::DegradationPhase.new(error_rate: 0.005)] * 120 +
                      [Semian::Experiments::DegradationPhase.new(error_rate: 0.60)] * 6 +
                      [Semian::Experiments::DegradationPhase.new(error_rate: 0.01)] * 6,
  phase_duration: 30,
  semian_config: {
    adaptive_circuit_breaker: true,
    bulkhead: false,
  },
  graph_title: "Adaptive Circuit Breaker: Lower Bound Integral Windup",
  graph_filename: "lower_bound_windup.png",
  x_axis_label_interval: 60,
)

runner.run
