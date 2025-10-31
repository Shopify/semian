# frozen_string_literal: true

require "test_helper"
require "semian/adaptive_circuit_breaker"

class TestAdaptiveCircuitBreaker < Minitest::Test
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

    assert_equal("successful_result", result)
  end

  def test_acquire_with_error_raises_and_records_request
    # Mock the PID controller to allow the request
    @breaker.pid_controller.expects(:should_reject?).returns(false)
    @breaker.pid_controller.expects(:record_request).with(:error)

    # Execute the block and verify it raises the error
    error = assert_raises(RuntimeError) do
      @breaker.acquire { raise "Something went wrong" }
    end

    assert_equal("Something went wrong", error.message)
    assert_equal("Something went wrong", @breaker.last_error.message)
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

    assert_equal("Rejected by adaptive circuit breaker", error.message)
    assert_equal(false, block_executed)
  end

  def test_update_thread_calls_pid_controller_update_every_window_size
    # Verify that the update thread is created and alive
    assert_instance_of(Thread, @breaker.update_thread)
    assert(@breaker.update_thread.alive?)

    # Track how many times wait_for_window is called
    wait_count = 0
    ready_to_progress = false

    @breaker.stub(:wait_for_window, -> {
      # Wait until we're ready to start
      Kernel.sleep(0.01) until ready_to_progress

      wait_count += 1
      # Stop the breaker after 3 waits
      @breaker.stop if wait_count >= 3
    }) do
      # Set up expectations before allowing the thread to progress
      # We call update after sleeping. And since we exit on the third sleep, we only expect 2 updates.
      @breaker.pid_controller.expects(:update).times(2)

      # Now allow the thread to start progressing
      ready_to_progress = true

      # Wait for the thread to complete
      Kernel.sleep(0.01) while @breaker.update_thread.alive?
    end

    assert_equal(false, @breaker.update_thread.alive?)
    assert_equal(3, wait_count)
  end
end
