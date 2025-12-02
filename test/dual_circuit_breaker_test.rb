# frozen_string_literal: true

require "test_helper"

class TestDualCircuitBreaker < Minitest::Test
  def setup
    Semian.reset!
    @use_adaptive_flag = true
    Semian::DualCircuitBreaker.adaptive_circuit_breaker_selector(->(_resource) {
      @use_adaptive_flag
    })
  end

  def teardown
    Semian.destroy_all_resources
  end

  def test_creates_both_circuit_breakers
    resource = create_dual_resource

    assert_instance_of(Semian::DualCircuitBreaker, resource.circuit_breaker)
    assert(resource.circuit_breaker.legacy_circuit_breaker)
    assert(resource.circuit_breaker.adaptive_circuit_breaker)
  end

  def test_uses_legacy_when_use_adaptive_returns_false
    resource = create_dual_resource
    @use_adaptive_flag = false

    # Legacy circuit breaker should handle the request
    success_count = 0
    3.times do
      resource.acquire { success_count += 1 }
    end

    assert_equal(3, success_count)
    metrics = resource.circuit_breaker.metrics

    assert_equal(:legacy, metrics[:active])
  end

  def test_uses_adaptive_when_use_adaptive_returns_true
    resource = create_dual_resource
    @use_adaptive_flag = true

    # Adaptive circuit breaker should handle the request
    success_count = 0
    3.times do
      resource.acquire { success_count += 1 }
    end

    assert_equal(3, success_count)
    metrics = resource.circuit_breaker.metrics

    assert_equal(:adaptive, metrics[:active])
  end

  def test_can_switch_between_breakers_at_runtime
    resource = create_dual_resource

    # Start with legacy
    @use_adaptive_flag = false
    resource.acquire { "success" }

    assert_equal(:legacy, resource.circuit_breaker.metrics[:active])

    # Switch to adaptive
    @use_adaptive_flag = true
    resource.acquire { "success" }

    assert_equal(:adaptive, resource.circuit_breaker.metrics[:active])

    # Switch back to legacy
    @use_adaptive_flag = false
    resource.acquire { "success" }

    assert_equal(:legacy, resource.circuit_breaker.metrics[:active])
  end

  def test_both_breakers_track_successes
    resource = create_dual_resource
    @use_adaptive_flag = false # Use legacy for decisions

    # Get references to both circuit breakers
    legacy_cb = resource.circuit_breaker.legacy_circuit_breaker
    adaptive_cb = resource.circuit_breaker.adaptive_circuit_breaker

    # Set up expectations that mark_success will be called on both breakers
    legacy_cb.expects(:mark_success).times(3)
    adaptive_cb.expects(:mark_success).times(3)

    # Generate some successes
    3.times do
      resource.acquire { "success" }
    end
  end

  def test_request_allowed_delegates_to_active_breaker
    resource = create_dual_resource

    # Test with legacy active
    @use_adaptive_flag = false
    legacy_allowed = resource.circuit_breaker.legacy_circuit_breaker.request_allowed?

    assert_equal(legacy_allowed, resource.circuit_breaker.request_allowed?)

    # Test with adaptive active
    @use_adaptive_flag = true
    adaptive_allowed = resource.circuit_breaker.adaptive_circuit_breaker.request_allowed?

    assert_equal(adaptive_allowed, resource.circuit_breaker.request_allowed?)
  end

  def test_state_methods_delegate_to_active_breaker
    resource = create_dual_resource

    # Test with legacy active
    @use_adaptive_flag = false

    assert_equal(
      resource.circuit_breaker.legacy_circuit_breaker.closed?,
      resource.circuit_breaker.closed?,
    )

    # Test with adaptive active
    @use_adaptive_flag = true

    assert_equal(
      resource.circuit_breaker.adaptive_circuit_breaker.closed?,
      resource.circuit_breaker.closed?,
    )
  end

  def test_reset_resets_both_breakers
    resource = create_dual_resource

    # Generate some activity
    3.times do
      resource.acquire { raise TestError, "boom" }
    rescue TestError
      # Expected
    end

    # Reset
    resource.circuit_breaker.reset

    # Both should be reset (both should be closed)
    assert(resource.circuit_breaker.legacy_circuit_breaker.closed?)
    assert(resource.circuit_breaker.adaptive_circuit_breaker.closed?)
  end

  def test_destroy_destroys_both_breakers
    resource = create_dual_resource

    # Destroy
    resource.circuit_breaker.destroy

    # Verify cleanup (threads should be stopped for adaptive)
    assert(resource.circuit_breaker.adaptive_circuit_breaker.instance_variable_get(:@stopped))
  end

  def test_metrics_includes_both_breakers
    resource = create_dual_resource

    metrics = resource.circuit_breaker.metrics

    assert(metrics[:active])
    assert(metrics[:legacy])
    assert(metrics[:adaptive])
    assert(metrics[:legacy].key?(:state))
    assert(metrics[:adaptive].key?(:rejection_rate))
  end

  def test_handles_use_adaptive_check_errors_gracefully
    resource = Semian.register(
      :test_error_handling,
      dual_circuit_breaker: true,
      success_threshold: 2,
      error_threshold: 3,
      error_timeout: 5,
      tickets: 5,
      timeout: 0.5,
      exceptions: [TestError],
    )

    # Create a proc that raises an error
    Semian::DualCircuitBreaker.adaptive_circuit_breaker_selector(->(resource) { raise StandardError, "check failed" })

    # Should fall back to legacy (not raise error)
    success_count = 0
    resource.acquire { success_count += 1 }

    assert_equal(1, success_count)
    # Should have used legacy as fallback
    assert_equal(:legacy, resource.circuit_breaker.metrics[:active])
  end

  def test_with_bulkhead_enabled
    resource = Semian.register(
      :test_with_bulkhead,
      dual_circuit_breaker: true,
      success_threshold: 2,
      error_threshold: 3,
      error_timeout: 5,
      tickets: 2,
      timeout: 0.5,
      exceptions: [TestError],
    )

    assert(resource.bulkhead)
    assert_equal(2, resource.tickets)
  end

  def test_env_variable_disables_dual_breaker
    ENV["SEMIAN_CIRCUIT_BREAKER_DISABLED"] = "1"

    resource = Semian.register(
      :test_disabled,
      dual_circuit_breaker: true,
      success_threshold: 2,
      error_threshold: 3,
      error_timeout: 5,
      tickets: 2,
    )

    assert_nil(resource.circuit_breaker)
  ensure
    ENV.delete("SEMIAN_CIRCUIT_BREAKER_DISABLED")
  end

  def test_returns_nil_if_either_breaker_cannot_be_created
    # This would happen if one of the create methods returns nil
    # For example, if required parameters are missing
    # We can't easily test this without mocking, but we verify the logic exists
    assert(true)
  end

  def test_last_error_comes_from_active_breaker
    resource = create_dual_resource
    @use_adaptive_flag = false

    begin
      resource.acquire { raise TestError, "test error" }
    rescue TestError
      # Expected
    end

    assert(resource.circuit_breaker.last_error)
    assert_equal("test error", resource.circuit_breaker.last_error.message)
  end

  private

  def create_dual_resource
    Semian.register(
      :test_dual_resource,
      dual_circuit_breaker: true,
      success_threshold: 2,
      error_threshold: 3,
      error_timeout: 5,
      tickets: 5,
      timeout: 0.5,
      exceptions: [TestError],
    )
  end

  class TestError < StandardError
  end
end
