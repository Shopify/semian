# frozen_string_literal: true

require "test_helper"
require "semian/pid_controller"

class TestPIDController < Minitest::Test
  include TimeHelper

  def setup
    @controller = Semian::ThreadSafe::PIDController.new(
      kp: 1.0,
      ki: 0.1,
      kd: 0.01,
      window_size: 10,
      initial_error_rate: 0.01,
      implementation: Semian::ThreadSafe,
      sliding_interval: 1,
    )
  end

  def teardown
    @controller.reset
    Process.unstub(:clock_gettime)
  end

  def test_initial_values
    assert_equal(
      {
        rejection_rate: 0.0,
        error_rate: 0.0,
        ideal_error_rate: 0.01,
        p_value: 0.0,
        previous_p_value: 0.0,
        integral: 0.0,
        derivative: 0.0,
        current_window_requests: { success: 0, error: 0, rejected: 0 },
        smoother_state: {
          smoothed_value: 0.01,
          alpha: 0.078,
          cap_value: 0.1,
          initial_value: 0.01,
          observations_per_minute: 60,
          observation_count: 0,
        },
      },
      @controller.metrics,
    )
  end

  def test_record_requests
    (0..2).each do |_|
      @controller.record_request(:success)
      @controller.record_request(:error)
      @controller.record_request(:rejected)
    end

    assert_equal({ success: 3, error: 3, rejected: 3 }, @controller.metrics[:current_window_requests])
  end

  def test_update_flow
    # Each iteration advances time by 1 second. Window is 10 seconds.
    elapsed = 0

    # Phase 1: Start with 1% error rate
    elapsed += sliding_interval_with_jitter
    time_travel(elapsed) do
      99.times { @controller.record_request(:success) }
      @controller.record_request(:error)
      @controller.update(sliding_interval_with_jitter)
    end

    # Rejection should be 0 when error rate is less than or equal to ideal
    assert_equal(0.0, @controller.metrics[:rejection_rate])
    assert_equal(1, @controller.metrics[:smoother_state][:observation_count])

    # Phase 2: Introduce error spike
    elapsed += sliding_interval_with_jitter
    time_travel(elapsed) do
      61.times { @controller.record_request(:success) }
      39.times { @controller.record_request(:error) }
      @controller.update(sliding_interval_with_jitter)
    end

    # Rejection should be around 20% (± 2%)
    assert_in_delta(0.20, @controller.metrics[:rejection_rate], 0.02, "Rejection should be ~20%")
    rejection_after_spike = @controller.metrics[:rejection_rate]

    # Phase 3: Continue high error rate (20% per window)
    5.times do
      elapsed += sliding_interval_with_jitter
      time_travel(elapsed) do
        80.times { @controller.record_request(:success) }
        20.times { @controller.record_request(:error) }
        @controller.update(sliding_interval_with_jitter)
      end
    end

    # After sustained errors, rejection should be at least as high as after the initial spike
    assert_operator(
      @controller.metrics[:rejection_rate],
      :>=,
      rejection_after_spike,
      "Rejection should remain elevated during sustained errors",
    )

    # Phase 4: Recovery - all successes to bring error rate down
    10.times do
      elapsed += sliding_interval_with_jitter
      time_travel(elapsed) do
        100.times { @controller.record_request(:success) }
        @controller.update(sliding_interval_with_jitter)
      end
    end

    # After 10 seconds of all successes (window fully refreshed),
    # all error data has expired, so rejection should be ~0
    assert_in_delta(0.0, @controller.metrics[:rejection_rate], 0.01, "Rejection should be ~0 after full recovery")
    assert_equal(0.0, @controller.metrics[:error_rate], "Error rate should be 0 after window expires")
  end

  def test_should_reject_probability
    @controller.instance_variable_set(:@rejection_rate, 0.5)

    # Mock rand to return deterministic values
    sequence = [0.3, 0.7, 0.4, 0.6, 0.2, 0.8, 0.5, 0.1, 0.9, 0.45]
    index = 0
    @controller.stub(:rand, -> {
      val = sequence[index % sequence.length]
      index += 1
      val
    }) do
      rejections = 0
      10.times do
        rejections += 1 if @controller.should_reject?
      end

      # With rejection_rate = 0.5, values < 0.5 should be rejected
      # From sequence: 0.3, 0.4, 0.2, 0.1, 0.45 = 5 rejections
      assert_equal(5, rejections)
    end
  end

  def test_reset_clears_all_state
    @controller.record_request(:error)
    @controller.update(1)

    @controller.reset

    assert_equal(
      {
        rejection_rate: 0.0,
        error_rate: 0.0,
        ideal_error_rate: 0.01,
        p_value: 0.0,
        previous_p_value: 0.0,
        integral: 0.0,
        derivative: 0.0,
        current_window_requests: { success: 0, error: 0, rejected: 0 },
        smoother_state: {
          smoothed_value: 0.01,
          alpha: 0.078,
          cap_value: 0.1,
          initial_value: 0.01,
          observations_per_minute: 60,
          observation_count: 0,
        },
      },
      @controller.metrics,
    )
  end

  def test_integral_anti_windup
    # Test that integral is clamped between -10 and 10

    # Test lower bound: integral should not go below -10
    # Simulate prolonged low error rate (below ideal) which would push integral negative
    100.times do
      100.times { @controller.record_request(:success) }
      @controller.update(1)
    end

    # Integral should be clamped at -10, not accumulate unbounded negative values
    assert_operator(@controller.metrics[:integral], :>=, -10.0, "Integral should not go below -10")

    @controller.reset

    # Test upper bound: integral should not go above 10
    # Simulate prolonged high error rate (100%) which would push integral positive
    50.times do
      100.times { @controller.record_request(:error) }
      @controller.update(1)
    end

    # Integral should be clamped at 10, not accumulate unbounded positive values
    assert_operator(@controller.metrics[:integral], :<=, 10.0, "Integral should not go above 10")
  end

  def test_sliding_window_behavior_of_controller
    time_travel(0.5) do
      @controller.record_request(:success)
      @controller.record_request(:success)
      @controller.record_request(:error)
    end

    time_travel(1.5) do
      @controller.record_request(:error)
    end

    time_travel(10) do
      @controller.update(1)

      # On the first 10 seconds, all requests are included
      assert_equal(0.5, @controller.metrics[:error_rate])
    end

    time_travel(11) do
      @controller.update(1)

      # On the 11th second, the first second is excluded, and we're left with 1 error, so 100%
      assert_equal(1.0, @controller.metrics[:error_rate])
    end
  end

  private

  def sliding_interval_with_jitter
    1 * rand(0.9..1.1)
  end
end

class TestThreadSafePIDController < Minitest::Test
  include TimeHelper

  def setup
    @controller = Semian::ThreadSafe::PIDController.new(
      kp: 1.0,
      ki: 0.1,
      kd: 0.01,
      window_size: 10,
      initial_error_rate: 0.01,
      implementation: Semian::ThreadSafe,
      sliding_interval: 1,
    )
  end

  def test_thread_safety
    threads = []
    errors = []

    # Create multiple threads that simultaneously update the controller
    10.times do |i|
      threads << Thread.new do
        100.times do
          if i.even?
            @controller.record_request(:error)
          else
            @controller.record_request(:success)
          end
        end
      rescue => e
        errors << e
      end
    end

    threads.each(&:join)

    # No errors should have occurred
    assert_empty(errors)
    # Values got updated correctly with no race conditions
    assert_equal(500, @controller.metrics[:current_window_requests][:error])
    assert_equal(500, @controller.metrics[:current_window_requests][:success])
  end

  def test_no_deadlocks
    # Confirm the code does not try to acquire the same lock twice
    @controller.update(1)
    @controller.record_request(:error)
    @controller.should_reject?
    @controller.reset

    # If any of the above has a deadlock, the test will hang, and we'll never reach this line
    assert(true) # rubocop:disable Minitest/UselessAssertion
  end
end
