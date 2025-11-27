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
      window_size: 0.05,
      initial_error_rate: 0.01,
      implementation: Semian::ThreadSafe,
      sliding_interval: 1,
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

  def test_update_thread_calls_pid_controller_update_after_every_wait_interval
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

  def test_notify_state_transition
    events = []
    Semian.subscribe(:test_breaker) do |event, resource, _scope, _adapter, payload|
      if event == :state_change
        events << { name: resource.name, state: payload[:state] }
      end
    end

    # Control when the update thread progresses
    ready_to_progress = false
    wait_count = 0

    @breaker.stub(:wait_for_window, -> {
      # Wait until we're ready to start
      Kernel.sleep(0.01) until ready_to_progress

      wait_count += 1
      # Stop the breaker after 6 waits
      @breaker.stop if wait_count >= 6
    }) do
      # Set up expectations before allowing the thread to progress
      @breaker.pid_controller.expects(:rejection_rate).returns(0.0, 0.0, 0.0, 0.5, 0.5, 0.5, 0.5, 0.0, 0.0, 0.0).times(10)
      @breaker.pid_controller.expects(:update).times(5)
      @breaker.pid_controller.expects(:metrics).returns({
        rejection_rate: 0.5,
        error_rate: 0.35,
        ideal_error_rate: 0.10,
        integral: 5.0,
        p_value: 0.1,
        derivative: 0.01,
        current_window_requests: { success: 10, error: 50, rejected: 5 },
      }).at_least_once

      # Now allow the thread to start progressing
      ready_to_progress = true

      # Wait for the thread to complete
      Kernel.sleep(0.01) while @breaker.update_thread&.alive?
    end

    # Should receive exactly 2 notifications (only when state actually changes)
    assert_equal(2, events.length)
    assert_equal(:test_breaker, events[0][:name])
    assert_equal(:open, events[0][:state])
    assert_equal(:test_breaker, events[1][:name])
    assert_equal(:closed, events[1][:state])
  ensure
    Semian.unsubscribe(:test_breaker)
  end

  def test_notify_adaptive_update
    events = []
    Semian.subscribe(:test_breaker) do |event, resource, _scope, _adapter, payload|
      if event == :adaptive_update
        events << {
          name: resource.name,
          rejection_rate: payload[:rejection_rate],
          error_rate: payload[:error_rate],
        }
      end
    end

    # Control when the update thread progresses
    ready_to_progress = false
    wait_count = 0

    @breaker.stub(:wait_for_window, -> {
      # Wait until we're ready to start
      Kernel.sleep(0.01) until ready_to_progress

      wait_count += 1
      # Stop the breaker after 3 waits
      @breaker.stop if wait_count >= 3
    }) do
      # Set up expectations before allowing the thread to progress
      @breaker.pid_controller.expects(:update).times(2)
      @breaker.pid_controller.expects(:rejection_rate).returns(0.25).at_least_once
      @breaker.pid_controller.expects(:metrics).returns({
        rejection_rate: 0.25,
        error_rate: 0.15,
        ideal_error_rate: 0.10,
        integral: 2.5,
        p_value: 0.05,
        derivative: 0.01,
        current_window_requests: { success: 15, error: 3, rejected: 5 },
      }).at_least(2)

      # Now allow the thread to start progressing
      ready_to_progress = true

      # Wait for the thread to complete
      Kernel.sleep(0.01) while @breaker.update_thread&.alive?
    end

    # Should receive 2 adaptive_update notifications (one per update)
    assert_equal(2, events.length)
    events.each do |event|
      assert_equal(:test_breaker, event[:name])
      assert_equal(0.25, event[:rejection_rate])
      assert_equal(0.15, event[:error_rate])
    end
  ensure
    Semian.unsubscribe(:test_breaker)
  end

  def test_state_transition_logging
    strio = StringIO.new
    original_logger = Semian.logger
    Semian.logger = Logger.new(strio)

    # Control when the update thread progresses
    ready_to_progress = false
    wait_count = 0

    @breaker.stub(:wait_for_window, -> {
      # Wait until we're ready to start
      Kernel.sleep(0.01) until ready_to_progress

      wait_count += 1
      # Stop the breaker after 2 waits
      @breaker.stop if wait_count >= 2
    }) do
      # Set up expectations before allowing the thread to progress
      # rejection_rate called twice: before update (0.0), after update (0.5)
      @breaker.pid_controller.expects(:rejection_rate).returns(0.0, 0.5).times(2)
      @breaker.pid_controller.expects(:update).once
      @breaker.pid_controller.expects(:metrics).returns({
        rejection_rate: 0.5,
        error_rate: 0.35,
        ideal_error_rate: 0.10,
        integral: 5.0,
        p_value: 0.1,
        derivative: 0.01,
        current_window_requests: { success: 10, error: 50, rejected: 5 },
      }).at_least_once

      # Now allow the thread to start progressing
      ready_to_progress = true

      # Wait for the thread to complete
      Kernel.sleep(0.01) while @breaker.update_thread&.alive?
    end

    log_output = strio.string

    # Verify log contains expected fields
    assert_match(/State transition from closed to open/, log_output)
    assert_match(/rejection_rate=50.0%/, log_output)
    assert_match(/error_rate=35.0%/, log_output)
    assert_match(/ideal_error_rate=10.0%/, log_output)
    assert_match(/integral=5.0/, log_output)
    assert_match(/success_count=10/, log_output)
    assert_match(/error_count=50/, log_output)
    assert_match(/rejected_count=5/, log_output)
    assert_match(/name="test_breaker"/, log_output)
  ensure
    Semian.logger = original_logger
  end
end
