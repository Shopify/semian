# frozen_string_literal: true

require "test_helper"
require "semian/adaptive_circuit_breaker"

class TestAdaptiveCircuitBreaker < Minitest::Test
  class MockClock
    attr_accessor :should_start

    def initialize(window_size: 10, max_sleeps: 3, &block)
      @sleep_count = 0
      @window_size = window_size
      @max_sleeps = max_sleeps
      @on_max_sleeps = block
      @should_start = false
    end

    def sleep(duration)
      until @should_start
        Kernel.sleep(0.01)
      end

      # Only count window_size sleeps, this helps us detect if the wrong value is being passed
      if duration == @window_size
        @sleep_count += 1
        @on_max_sleeps.call if @sleep_count >= @max_sleeps && @on_max_sleeps
      end
    end
  end

  def setup
    @breaker = Semian::AdaptiveCircuitBreaker.new(
      name: "test_breaker",
      kp: 1.0,
      ki: 0.1,
      kd: 0.01,
      window_size: 10,
      initial_history_duration: 100,
      initial_error_rate: 0.01,
      thread_safe: true,
    )
  end

  def teardown
    @breaker.stop
  end

  def test_acquire_with_success_returns_value_and_records_request
    # Mock the PID controller to allow the request
    @breaker.pid_controller.expects(:should_reject?).returns(false)
    @breaker.pid_controller.expects(:record_request).with(:success)

    # Execute the block and verify it returns the expected value
    result = @breaker.acquire { "successful_result" }

    assert_equal "successful_result", result
  end

  def test_acquire_with_error_raises_and_records_request
    # Mock the PID controller to allow the request
    @breaker.pid_controller.expects(:should_reject?).returns(false)
    @breaker.pid_controller.expects(:record_request).with(:error)

    # Execute the block and verify it raises the error
    error = assert_raises(RuntimeError) do
      @breaker.acquire { raise "Something went wrong" }
    end

    assert_equal "Something went wrong", error.message
    assert_equal "Something went wrong", @breaker.last_error.message
  end

  def test_acquire_with_rejection_raises_and_records_request
    # Mock the PID controller to reject the request
    @breaker.pid_controller.expects(:should_reject?).returns(true)
    @breaker.pid_controller.expects(:record_request).with(:rejected)

    # Verify that OpenCircuitError is raised and the block is never executed
    block_executed = false

    error = assert_raises(Semian::OpenCircuitError) do
      @breaker.acquire do
        block_executed = true
        "should not be executed"
      end
    end

    assert_equal "Rejected by adaptive circuit breaker", error.message
    assert_equal false, block_executed
  end

  def test_update_thread_calls_pid_controller_update_every_window_size
    breaker = nil

    done = false
    mock_clock = MockClock.new(max_sleeps: 3) do |_|
      done = true
      # Note: breaker.stop kills the thread. Any line after it will not be executed.
      breaker.stop
    end

    breaker = Semian::AdaptiveCircuitBreaker.new(
      name: "test_breaker_with_clock",
      kp: 1.0,
      ki: 0.1,
      kd: 0.01,
      window_size: 10,
      initial_history_duration: 100,
      initial_error_rate: 0.01,
      thread_safe: true,
      clock: mock_clock,
    )

    # Verify that the update thread is created and alive
    assert_instance_of Thread, breaker.update_thread
    assert breaker.update_thread.alive?

    mock_clock.should_start = true

    # We call update after sleeping. And since we exit on the third sleep, we only expect 2 updates.
    breaker.pid_controller.expects(:update).times(2)

    until done
      Kernel.sleep(0.01)
    end

    assert_equal false, breaker.update_thread.alive?
  end
end
