# frozen_string_literal: true

require "test_helper"

class TestSemianAdaptiveConfig < Minitest::Test
  def teardown
    Semian.destroy_all_resources
  end

  def test_register_with_adaptive_circuit_breaker
    resource = Semian.register(
      :test_adaptive,
      adaptive_circuit_breaker: true,
      bulkhead: false,
    )

    assert_instance_of(Semian::ProtectedResource, resource)
    assert_instance_of(Semian::AdaptiveCircuitBreaker, resource.circuit_breaker)
  end

  def test_adaptive_circuit_breaker_disabled_by_env
    ENV["SEMIAN_ADAPTIVE_CIRCUIT_BREAKER_DISABLED"] = "1"

    resource = Semian.register(
      :test_adaptive_disabled,
      adaptive_circuit_breaker: true,
      bulkhead: true,
      tickets: 1,
    )

    assert_instance_of(Semian::ProtectedResource, resource)
    assert_nil(resource.circuit_breaker)
  ensure
    ENV.delete("SEMIAN_ADAPTIVE_CIRCUIT_BREAKER_DISABLED")
  end

  def test_traditional_circuit_breaker_still_works
    resource = Semian.register(
      :test_traditional,
      circuit_breaker: true,
      success_threshold: 2,
      error_threshold: 3,
      error_timeout: 10,
      bulkhead: false,
    )

    assert_instance_of(Semian::ProtectedResource, resource)
    assert_instance_of(Semian::CircuitBreaker, resource.circuit_breaker)
  end

  def test_adaptive_overrides_traditional_when_enabled
    resource = Semian.register(
      :test_override,
      adaptive_circuit_breaker: true,
      circuit_breaker: true, # This should be ignored
      success_threshold: 2, # These traditional params should be ignored
      error_threshold: 3,
      error_timeout: 10,
      bulkhead: false,
    )

    assert_instance_of(Semian::AdaptiveCircuitBreaker, resource.circuit_breaker)
  end

  def test_adaptive_circuit_breaker_with_bulkhead
    resource = Semian.register(
      :test_combined,
      adaptive_circuit_breaker: true,
      bulkhead: true,
      tickets: 5,
      timeout: 1,
    )

    assert_instance_of(Semian::ProtectedResource, resource)
    assert_instance_of(Semian::AdaptiveCircuitBreaker, resource.circuit_breaker)
    assert_instance_of(Semian::Resource, resource.bulkhead)
    assert_equal(5, resource.tickets)
  end

  def test_retrieve_adaptive_resource
    Semian.register(
      :test_retrieve,
      adaptive_circuit_breaker: true,
      bulkhead: false,
    )

    resource = Semian[:test_retrieve]

    assert_instance_of(Semian::ProtectedResource, resource)
    assert_instance_of(Semian::AdaptiveCircuitBreaker, resource.circuit_breaker)
  end

  def test_adaptive_circuit_breaker_default_params
    resource = Semian.register(
      :test_defaults,
      adaptive_circuit_breaker: true,
      bulkhead: false,
    )

    controller = resource.circuit_breaker.pid_controller
    metrics = controller.metrics

    # Check that defaults were applied
    assert_equal(0.0, metrics[:rejection_rate])
    assert(resource.circuit_breaker.ping_thread&.alive?) # Background ping is enabled by default
  end

  def test_resource_cleanup_with_adaptive
    resource = Semian.register(
      :test_cleanup,
      adaptive_circuit_breaker: true,
      bulkhead: false,
    )

    assert(resource.circuit_breaker.ping_thread&.alive?)

    Semian.destroy(:test_cleanup)

    # After destroy, the ping thread should be stopped
    # (the destroy method should call stop on the adaptive circuit breaker)
  end
end
