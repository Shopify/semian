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
      Kernel.sleep(0.01) until @should_start

      # Only count window_size sleeps, this helps us detect if the wrong value is being passed
      if duration == @window_size
        @sleep_count += 1
        @on_max_sleeps.call if @sleep_count >= @max_sleeps && @on_max_sleeps
      end
    end
  end

  def create_test_breaker(name:, clock: nil)
    Semian::AdaptiveCircuitBreaker.new(
      name: name,
      kp: 1.0,
      ki: 0.1,
      kd: 0.01,
      window_size: 10,
      initial_history_duration: 100,
      initial_error_rate: 0.01,
      thread_safe: true,
      clock: clock,
    )
  end

  def setup
    @breaker = create_test_breaker(name: "test_breaker")
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
    breaker = nil

    done = false
    mock_clock = MockClock.new(max_sleeps: 3) do |_|
      done = true
      # NOTE: breaker.stop kills the thread. Any line after it will not be executed.
      breaker.stop
    end

    breaker = create_test_breaker(name: "test_breaker_with_clock", clock: mock_clock)

    # Verify that the update thread is created and alive
    assert_instance_of(Thread, breaker.update_thread)
    assert(breaker.update_thread.alive?)

    mock_clock.should_start = true

    # We call update after sleeping. And since we exit on the third sleep, we only expect 2 updates.
    breaker.pid_controller.expects(:update).times(2)

    Kernel.sleep(0.01) until done

    assert_equal(false, breaker.update_thread.alive?)
  end

  def test_notify_state_transition
    events = []
    Semian.subscribe(:test_notify) do |event, resource, _scope, _adapter, payload|
      if event == :state_change
        events << { name: resource.name, state: payload[:state] }
      end
    end

    breaker = nil
    done = false
    mock_clock = MockClock.new(max_sleeps: 6) do |_|
      done = true
      breaker.stop
    end

    breaker = create_test_breaker(name: "test_notify", clock: mock_clock)

    breaker.pid_controller.expects(:rejection_rate).returns(0.0, 0.0, 0.5, 0.5, 0.0).times(5)
    breaker.pid_controller.expects(:update).times(5)
    breaker.pid_controller.expects(:metrics).returns({
      rejection_rate: 0.5,
      error_rate: 0.35,
      ideal_error_rate: 0.10,
      integral: 5.0,
      p_value: 0.1,
      derivative: 0.01,
      current_window_requests: { success: 10, error: 50, rejected: 5 },
    }).at_least_once

    mock_clock.should_start = true
    Kernel.sleep(0.01) until done

    # Should receive exactly 2 notifications (only when state actually changes)
    assert_equal(2, events.length)
    assert_equal(:test_notify, events[0][:name])
    assert_equal(:open, events[0][:state])
    assert_equal(:test_notify, events[1][:name])
    assert_equal(:closed, events[1][:state])
  ensure
    Semian.unsubscribe(:test_notify)
  end

  def test_notify_adaptive_update
    events = []
    Semian.subscribe(:test_adaptive_update) do |event, resource, _scope, _adapter, payload|
      if event == :adaptive_update
        events << {
          name: resource.name,
          rejection_rate: payload[:rejection_rate],
          error_rate: payload[:error_rate],
        }
      end
    end

    breaker = nil
    done = false
    mock_clock = MockClock.new(max_sleeps: 3) do |_|
      done = true
      breaker.stop
    end

    breaker = create_test_breaker(name: "test_adaptive_update", clock: mock_clock)

    breaker.pid_controller.expects(:update).times(2)
    breaker.pid_controller.expects(:rejection_rate).returns(0.25).at_least_once
    breaker.pid_controller.expects(:metrics).returns({
      rejection_rate: 0.25,
      error_rate: 0.15,
      ideal_error_rate: 0.10,
      integral: 2.5,
      p_value: 0.05,
      derivative: 0.01,
      current_window_requests: { success: 15, error: 3, rejected: 5 },
    }).at_least(2)

    mock_clock.should_start = true
    Kernel.sleep(0.01) until done

    # Should receive 2 adaptive_update notifications (one per update)
    assert_equal(2, events.length)
    events.each do |event|
      assert_equal(:test_adaptive_update, event[:name])
      assert_equal(0.25, event[:rejection_rate])
      assert_equal(0.15, event[:error_rate])
    end
  ensure
    Semian.unsubscribe(:test_adaptive_update)
  end

  def test_state_transition_logging
    strio = StringIO.new
    Semian.logger = Logger.new(strio)

    breaker = nil
    done = false
    mock_clock = MockClock.new(max_sleeps: 2) do |_|
      done = true
      breaker.stop
    end

    breaker = create_test_breaker(name: "test_logging", clock: mock_clock)

    breaker.pid_controller.expects(:rejection_rate).returns(0.5).once
    breaker.pid_controller.expects(:update).once
    breaker.pid_controller.expects(:metrics).returns({
      rejection_rate: 0.5,
      error_rate: 0.35,
      ideal_error_rate: 0.10,
      integral: 5.0,
      p_value: 0.1,
      derivative: 0.01,
      current_window_requests: { success: 10, error: 50, rejected: 5 },
    }).at_least_once

    mock_clock.should_start = true
    Kernel.sleep(0.01) until done

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
    assert_match(/name="test_logging"/, log_output)
  end
end
