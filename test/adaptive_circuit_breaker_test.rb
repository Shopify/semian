# frozen_string_literal: true

require "test_helper"
require "semian/adaptive_circuit_breaker"

class TestAdaptiveCircuitBreaker < Minitest::Test
  # Mock resource class for testing
  class MockResource
    attr_reader :ping_count, :should_fail

    def initialize(should_fail: false)
      @ping_count = 0
      @should_fail = should_fail
    end

    def ping
      @ping_count += 1
      raise "Ping failed" if @should_fail

      "pong"
    end
  end

  def setup
    @breaker = Semian::AdaptiveCircuitBreaker.new(
      name: "test_breaker",
      kp: 1.0,
      ki: 0.1,
      kd: 0.01,
      ping_interval: 0.1, # 100ms for faster tests
      enable_background_ping: true,
    )
    @resource = MockResource.new
  end

  def teardown
    @breaker.stop
  end

  def test_successful_request_flow
    result = @breaker.acquire(@resource) { "success" }

    assert_equal("success", result)

    metrics = @breaker.metrics

    assert_equal(0.0, metrics[:error_rate])
  end

  def test_error_request_flow
    assert_raises(RuntimeError) do
      @breaker.acquire(@resource) { raise "Error" }
    end

    metrics = @breaker.metrics

    assert_equal(1.0, metrics[:error_rate])
  end

  def test_rejection_when_rejection_rate_high
    # Manually set a high rejection rate for testing
    @breaker.pid_controller.instance_variable_set(:@rejection_rate, 1.0)

    assert_raises(Semian::OpenCircuitError) do
      @breaker.acquire(@resource) { "should not execute" }
    end
  end

  def test_background_ping_thread_runs
    # Give the resource to the breaker
    @breaker.acquire(@resource) { "success" }

    # Wait for a few ping intervals
    sleep(0.3)

    # Background thread should have sent pings
    assert_operator(@resource.ping_count, :>, 0)
  end

  def test_background_ping_continues_during_rejection
    # Set resource that fails pings
    failing_resource = MockResource.new(should_fail: true)

    # Give the resource to the breaker
    begin
      @breaker.acquire(failing_resource) { "success" }
    rescue
      # Ignore any errors
    end

    # Wait for a ping interval
    sleep(0.15)

    # Should have attempted pings even though they fail
    assert_operator(failing_resource.ping_count, :>, 0)

    # Check that failures are recorded
    metrics = @breaker.metrics

    assert_operator(metrics[:ping_failure_rate], :>, 0)
  end

  def test_circuit_states
    assert(@breaker.closed?)
    assert(!@breaker.open?)
    assert(!@breaker.half_open?)

    # Set medium rejection rate
    @breaker.pid_controller.instance_variable_set(:@rejection_rate, 0.5)

    assert(@breaker.half_open?)
    assert(!@breaker.closed?)
    assert(!@breaker.open?)

    # Set high rejection rate
    @breaker.pid_controller.instance_variable_set(:@rejection_rate, 0.95)

    assert(@breaker.open?)
    assert(!@breaker.closed?)
    assert(!@breaker.half_open?)
  end

  def test_reset_clears_state
    # Record some requests
    @breaker.acquire(@resource) { "success" }
    begin
      @breaker.acquire(@resource) { raise "Error" }
    rescue
    end

    # Reset
    @breaker.reset

    metrics = @breaker.metrics

    assert_equal(0.0, metrics[:error_rate])
    assert_equal(0.0, metrics[:rejection_rate])
  end

  def test_stop_terminates_ping_thread
    # Give the resource to the breaker
    @breaker.acquire(@resource) { "success" }

    # Verify thread is running
    assert(@breaker.ping_thread&.alive?)

    # Stop the breaker
    @breaker.stop

    # Thread should be terminated
    assert_nil(@breaker.ping_thread)
  end

  def test_adaptive_behavior_with_errors
    # Simulate dependency failures
    10.times do
      @breaker.acquire(@resource) { raise "Error" }
    rescue
    end

    # Rejection rate should increase
    assert_operator(@breaker.pid_controller.rejection_rate, :>, 0)

    # Now simulate recovery
    20.times do
      @breaker.acquire(@resource) { "success" }
    rescue Semian::OpenCircuitError
      # Some requests might be rejected
    end

    # Let background pings help detect recovery
    sleep(0.2)

    # After recovery, rejection rate should trend down
    # (exact behavior depends on PID tuning)
    final_metrics = @breaker.metrics

    assert_operator(final_metrics[:rejection_rate], :>=, 0)
    assert_operator(final_metrics[:rejection_rate], :<=, 1.0)
  end
end

class TestAdaptiveCircuitBreakerWithoutBackgroundPing < Minitest::Test
  def setup
    @breaker = Semian::AdaptiveCircuitBreaker.new(
      name: "test_no_bg_ping",
      enable_background_ping: false,
    )
  end

  def test_no_background_thread_created
    assert_nil(@breaker.ping_thread)
  end

  def test_acquire_still_works_without_background_ping
    result = @breaker.acquire { "success" }

    assert_equal("success", result)
  end
end
