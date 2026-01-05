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
    assert_instance_of(Semian::DualCircuitBreaker::ChildClassicCircuitBreaker, resource.circuit_breaker.classic_circuit_breaker)
    assert_instance_of(Semian::DualCircuitBreaker::ChildAdaptiveCircuitBreaker, resource.circuit_breaker.adaptive_circuit_breaker)
  end

  def test_uses_classic_when_use_adaptive_returns_false
    resource = create_dual_resource
    @use_adaptive_flag = false

    resource.acquire { "success" }

    assert_instance_of(Semian::DualCircuitBreaker::ChildClassicCircuitBreaker, resource.circuit_breaker.active_circuit_breaker)
  end

  def test_uses_adaptive_when_use_adaptive_returns_true
    resource = create_dual_resource
    @use_adaptive_flag = true

    resource.acquire { "success" }

    assert_instance_of(Semian::DualCircuitBreaker::ChildAdaptiveCircuitBreaker, resource.circuit_breaker.active_circuit_breaker)
  end

  def test_can_switch_between_breakers_at_runtime
    resource = create_dual_resource

    # Start with classic
    @use_adaptive_flag = false
    resource.acquire { "success" }

    assert_instance_of(Semian::DualCircuitBreaker::ChildClassicCircuitBreaker, resource.circuit_breaker.active_circuit_breaker)

    # Switch to adaptive
    @use_adaptive_flag = true
    resource.acquire { "success" }

    assert_instance_of(Semian::DualCircuitBreaker::ChildAdaptiveCircuitBreaker, resource.circuit_breaker.active_circuit_breaker)

    # Switch back to classic
    @use_adaptive_flag = false
    resource.acquire { "success" }

    assert_instance_of(Semian::DualCircuitBreaker::ChildClassicCircuitBreaker, resource.circuit_breaker.active_circuit_breaker)
  end

  def test_both_breakers_record_requests
    resource = create_dual_resource
    @use_adaptive_flag = false

    classic_cb = resource.circuit_breaker.classic_circuit_breaker
    adaptive_cb = resource.circuit_breaker.adaptive_circuit_breaker

    # In the classic circuit breaker, mark_success doesn't result in any state change on a closed circuit,
    # and just returns. So we have to use mocks to ensure it's being called.
    #
    # Here, we selectively mock only the mark_success method on the superclass.
    # This allows mark_success to be called on the sibling circuit breaker,
    # so it can also record metrics.
    classic_cb.class.superclass.any_instance.expects(:mark_success).times(2)

    2.times { resource.acquire { "success" } }

    adaptive_metrics = adaptive_cb.pid_controller.metrics

    assert_equal(2, adaptive_metrics[:current_window_requests][:success])

    begin
      resource.acquire { raise TestError, "test error" }
    rescue TestError
      nil
    end

    assert_equal(1, classic_cb.instance_variable_get(:@errors).size)
    assert_equal("test error", adaptive_cb.last_error.message)
    adaptive_metrics = adaptive_cb.pid_controller.metrics

    assert_equal(1, adaptive_metrics[:current_window_requests][:error])
  end

  def test_destroy_destroys_both_breakers
    resource = create_dual_resource

    resource.circuit_breaker.destroy

    assert(resource.circuit_breaker.adaptive_circuit_breaker.instance_variable_get(:@stopped))
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

    Semian::DualCircuitBreaker.adaptive_circuit_breaker_selector(->(_resource) { raise StandardError, "check failed" })

    success_count = 0
    resource.acquire { success_count += 1 }

    assert_equal(1, success_count)
    assert_instance_of(Semian::DualCircuitBreaker::ChildClassicCircuitBreaker, resource.circuit_breaker.active_circuit_breaker)
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

  def test_both_breakers_track_last_error
    resource = create_dual_resource

    begin
      resource.acquire { raise TestError, "test error" }
    rescue TestError
      nil # expected
    end

    assert_equal("test error", resource.circuit_breaker.last_error.message)
    assert_equal("test error", resource.circuit_breaker.classic_circuit_breaker.last_error.message)
    assert_equal("test error", resource.circuit_breaker.adaptive_circuit_breaker.last_error.message)
  end

  def test_active_breaker_type
    resource = create_dual_resource

    @use_adaptive_flag = false
    resource.acquire { "success" }

    assert_instance_of(Semian::DualCircuitBreaker::ChildClassicCircuitBreaker, resource.circuit_breaker.classic_circuit_breaker)

    @use_adaptive_flag = true
    resource.acquire { "success" }

    assert_instance_of(Semian::DualCircuitBreaker::ChildAdaptiveCircuitBreaker, resource.circuit_breaker.adaptive_circuit_breaker)
  end

  def test_notifies_on_mode_change
    resource = create_dual_resource
    notifications = []

    subscription = Semian.subscribe do |event, _, _, _, payload|
      notifications << { event: event, payload: payload } if event == :circuit_breaker_mode_change
    end

    @use_adaptive_flag = false
    resource.acquire { "success" }

    @use_adaptive_flag = true
    resource.acquire { "success" }

    assert_equal(1, notifications.size)
    assert_equal(:classic, notifications[0][:payload][:old_mode])
    assert_equal(:adaptive, notifications[0][:payload][:new_mode])

    @use_adaptive_flag = false
    resource.acquire { "success" }

    assert_equal(2, notifications.size)
    assert_equal(:adaptive, notifications[1][:payload][:old_mode])
    assert_equal(:classic, notifications[1][:payload][:new_mode])
  ensure
    Semian.unsubscribe(subscription)
  end

  def test_dual_circuit_breaker_is_not_used_when_configuration_is_not_specified
    resource = Semian.register(
      :test_classic_circuit_breaker,
      circuit_breaker: true,
      success_threshold: 2,
      error_threshold: 3,
      error_timeout: 5,
      tickets: 5,
      timeout: 0.5,
      exceptions: [TestError],
    )

    assert_instance_of(Semian::CircuitBreaker, resource.circuit_breaker)
    refute_instance_of(Semian::DualCircuitBreaker, resource.circuit_breaker)
    refute_instance_of(Semian::AdaptiveCircuitBreaker, resource.circuit_breaker)
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
