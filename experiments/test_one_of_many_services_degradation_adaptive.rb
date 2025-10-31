# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "semian"
require_relative "mock_service"
require_relative "experimental_resource"
require_relative "test_helpers"

runner = Semian::Experiments::CircuitBreakerTestRunner.new(
  test_name: "One of Many Services Degradation Test",
  resource_name: "protected_service_adaptive",
  degradation_phases: [Semian::Experiments::DegradationPhase.new(healthy: true)] * 1 +
                      [Semian::Experiments::DegradationPhase.new(latency: 4.95)] * 10 + # Most requests to the target service will timeout
                      [Semian::Experiments::DegradationPhase.new(healthy: true)] * 3,
  phase_duration: 30,
  service_count: 10,
  semian_config: {
    adaptive_circuit_breaker: true,
    bulkhead: false,
  },
  graph_title: "Adaptive Circuit Breaker: One of Many Services Latency Degradation",
  graph_filename: "one_of_many_services_latency_degradation_adaptive.png",
  x_axis_label_interval: 30,
)

runner.run
