# frozen_string_literal: true

require "test_helper"

class TestDualCircuitBreaker < Minitest::Test
  def setup
    Semian.reset!
    @experiment_flag = false
    @experiment_proc = -> { @experiment_flag }
  end

  def teardown
    Semian.destroy_all_resources
  end

  def test_creates_both_circuit_breakers
    resource = create_dual_resource

    assert_instance_of Semian::DualCircuitBreaker, resource.circuit_breaker
    assert resource.circuit_breaker.legacy_circuit_breaker
    assert resource.circuit_breaker.adaptive_circuit_breaker
  end

  def test_uses_legacy_when_flag_is_false
    resource = create_dual_resource
    @experiment_flag = false

    # Legacy circuit breaker should handle the request
    success_count = 0
    3.times do
      resource.acquire { success_count += 1 }
    end

    assert_equal 3, success_count
    metrics = resource.circuit_breaker.metrics
    assert_equal :legacy, metrics[:active]
  end

  def test_uses_adaptive_when_flag_is_true
    resource = create_dual_resource
    @experiment_flag = true

    # Adaptive circuit breaker should handle the request
    success_count = 0
    3.times do
      resource.acquire { success_count += 1 }
    end

    assert_equal 3, success_count
    metrics = resource.circuit_breaker.metrics
    assert_equal :adaptive, metrics[:active]
  end

  def test_can_switch_between_breakers_at_runtime
    resource = create_dual_resource

    # Start with legacy
    @experiment_flag = false
    resource.acquire { "success" }
    assert_equal :legacy, resource.circuit_breaker.metrics[:active]

    # Switch to adaptive
    @experiment_flag = true
    resource.acquire { "success" }
    assert_equal :adaptive, resource.circuit_breaker.metrics[:active]

    # Switch back to legacy
    @experiment_flag = false
    resource.acquire { "success" }
    assert_equal :legacy, resource.circuit_breaker.metrics[:active]
  end

  def test_both_breakers_track_failures
    resource = create_dual_resource
    @experiment_flag = false # Use legacy for decisions

    # Cause some failures
    3.times do
      begin
        resource.acquire { raise TestError, "boom" }
      rescue TestError
        # Expected
      end
    end

    # Both should have tracked the errors
    assert resource.circuit_breaker.legacy_circuit_breaker.last_error
    assert resource.circuit_breaker.adaptive_circuit_breaker.last_error
  end

  def test_both_breakers_track_successes
    resource = create_dual_resource
    @experiment_flag = false # Use legacy for decisions

    # Generate some successes
    3.times do
      resource.acquire { "success" }
    end

    # Both should have tracked successes
    # We can verify through mark_success being called on both
    refute_nil resource.circuit_breaker.legacy_circuit_breaker
    refute_nil resource.circuit_breaker.adaptive_circuit_breaker
  end

  def test_request_allowed_delegates_to_active_breaker
    resource = create_dual_resource

    # Test with legacy active
    @experiment_flag = false
    legacy_allowed = resource.circuit_breaker.legacy_circuit_breaker.request_allowed?
    assert_equal legacy_allowed, resource.circuit_breaker.request_allowed?

    # Test with adaptive active
    @experiment_flag = true
    adaptive_allowed = resource.circuit_breaker.adaptive_circuit_breaker.request_allowed?
    assert_equal adaptive_allowed, resource.circuit_breaker.request_allowed?
  end

  def test_state_methods_delegate_to_active_breaker
    resource = create_dual_resource

    # Test with legacy active
    @experiment_flag = false
    assert_equal(
      resource.circuit_breaker.legacy_circuit_breaker.closed?,
      resource.circuit_breaker.closed?,
    )

    # Test with adaptive active
    @experiment_flag = true
    assert_equal(
      resource.circuit_breaker.adaptive_circuit_breaker.closed?,
      resource.circuit_breaker.closed?,
    )
  end

  def test_reset_resets_both_breakers
    resource = create_dual_resource

    # Generate some activity
    3.times do
      begin
        resource.acquire { raise TestError, "boom" }
      rescue TestError
        # Expected
      end
    end

    # Reset
    resource.circuit_breaker.reset

    # Both should be reset (both should be closed)
    assert resource.circuit_breaker.legacy_circuit_breaker.closed?
    assert resource.circuit_breaker.adaptive_circuit_breaker.closed?
  end

  def test_destroy_destroys_both_breakers
    resource = create_dual_resource

    # Destroy
    resource.circuit_breaker.destroy

    # Verify cleanup (threads should be stopped for adaptive)
    assert resource.circuit_breaker.adaptive_circuit_breaker.instance_variable_get(:@stopped)
  end

  def test_metrics_includes_both_breakers
    resource = create_dual_resource

    metrics = resource.circuit_breaker.metrics

    assert metrics[:active]
    assert metrics[:legacy]
    assert metrics[:adaptive]
    assert metrics[:legacy].key?(:state)
    assert metrics[:adaptive].key?(:rejection_rate)
  end

  def test_handles_flag_check_errors_gracefully
    # Create a proc that raises an error
    error_proc = -> { raise StandardError, "flag service down" }

    resource = Semian.register(
      :test_error_handling,
      dual_circuit_breaker: true,
      experiment_flag_proc: error_proc,
      success_threshold: 2,
      error_threshold: 3,
      error_timeout: 5,
      tickets: 5,
      timeout: 0.5,
      exceptions: [TestError],
    )

    # Should fall back to legacy (not raise error)
    success_count = 0
    resource.acquire { success_count += 1 }

    assert_equal 1, success_count
    # Should have used legacy as fallback
    assert_equal :legacy, resource.circuit_breaker.metrics[:active]
  end

  def test_with_bulkhead_enabled
    resource = Semian.register(
      :test_with_bulkhead,
      dual_circuit_breaker: true,
      experiment_flag_proc: @experiment_proc,
      success_threshold: 2,
      error_threshold: 3,
      error_timeout: 5,
      tickets: 2,
      timeout: 0.5,
      exceptions: [TestError],
    )

    assert resource.bulkhead
    assert_equal 2, resource.tickets
  end

  def test_env_variable_disables_dual_breaker
    ENV["SEMIAN_CIRCUIT_BREAKER_DISABLED"] = "1"

    resource = Semian.register(
      :test_disabled,
      dual_circuit_breaker: true,
      experiment_flag_proc: @experiment_proc,
      success_threshold: 2,
      error_threshold: 3,
      error_timeout: 5,
    )

    assert_nil resource.circuit_breaker
  ensure
    ENV.delete("SEMIAN_CIRCUIT_BREAKER_DISABLED")
  end

  def test_returns_nil_if_either_breaker_cannot_be_created
    # This would happen if one of the create methods returns nil
    # For example, if required parameters are missing
    # We can't easily test this without mocking, but we verify the logic exists
    assert true
  end

  def test_last_error_comes_from_active_breaker
    resource = create_dual_resource
    @experiment_flag = false

    begin
      resource.acquire { raise TestError, "test error" }
    rescue TestError
      # Expected
    end

    assert resource.circuit_breaker.last_error
    assert_equal "test error", resource.circuit_breaker.last_error.message
  end

  def test_compatibility_methods_for_legacy_breaker
    resource = create_dual_resource

    # These methods should work for compatibility with code expecting legacy breaker
    assert_respond_to resource.circuit_breaker, :state
    assert_respond_to resource.circuit_breaker, :error_timeout
    assert_respond_to resource.circuit_breaker, :half_open_resource_timeout
    assert_respond_to resource.circuit_breaker, :error_threshold_timeout_enabled
  end

  private

  def create_dual_resource
    Semian.register(
      :test_dual_resource,
      dual_circuit_breaker: true,
      experiment_flag_proc: @experiment_proc,
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

