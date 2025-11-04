# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "semian"
require_relative "mock_service"
require_relative "experimental_resource"
require_relative "test_helpers"

runner = Semian::Experiments::CircuitBreakerTestRunner.new(
  test_name: "Slow Query Test (Adaptive)",
  resource_name: "protected_service",
  degradation_phases: [Semian::Experiments::DegradationPhase.new(healthy: true)] * 1 +
                      [Semian::Experiments::DegradationPhase.new(specific_endpoint_latency: 9.0)] * 10 + # This should lead the service to get overwhelmed and start rejecting requests
                      [Semian::Experiments::DegradationPhase.new(healthy: true)] * 3,
  phase_duration: 30,
  service_count: 10,
  with_max_threads: true,
  semian_config: {
    adaptive_circuit_breaker: true,
    bulkhead: false,
  },
  graph_title: "Adaptive Circuit Breaker: Slow Query Test",
  graph_filename: "slow_query_adaptive.png",
  x_axis_label_interval: 30,
)

runner.run
