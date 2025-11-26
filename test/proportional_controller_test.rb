# frozen_string_literal: true

require "test_helper"
require "semian/proportional_controller"

class TestProportionalController < Minitest::Test
  include TimeHelper

  def setup
    @controller = Semian::ThreadSafe::ProportionalController.new(
      defensiveness: 5.0,
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
    # Start with error rate equal to the ideal error rate (1%)
    # update should maintain a rejection rate of 0

    current_time = travel_10_seconds(1) do
      record_100_requests(1)
      @controller.update

      assert_equal(0, @controller.metrics[:rejection_rate])
      assert_in_delta(0.01, @controller.metrics[:smoother_state][:smoothed_value], 0.001)
    end

    # run another time, nothing should change
    current_time = travel_10_seconds(current_time) do
      record_100_requests(1)

      @controller.update

      assert_equal(0, @controller.metrics[:rejection_rate])
      assert_in_delta(0.01, @controller.metrics[:smoother_state][:smoothed_value], 0.001)
    end

    # Error rate now goes below the ideal error rate. Rejection rate should be unaffected.
    current_time = travel_10_seconds(current_time) do
      record_100_requests(0)
      @controller.update

      assert_equal(0, @controller.metrics[:rejection_rate])
    end

    # ------------------------------------------------------------
    # Error rate now goes above the ideal error rate. Rejection rate should increase.
    current_time = travel_10_seconds(current_time) do
      record_100_requests(16)
      @controller.update
      # p_value = (error_rate - ideal_error_rate) - (1/defensiveness) * rejection_rate
      # p_value = (0.16 - 0.01) - (1/5) * 0 = 0.15 - 0 = 0.15
      assert_in_delta(@controller.metrics[:rejection_rate], 0.15, 0.001)
    end
    # Rejection rate should converge towards 5x the error rate within 20 iterations
    20.times do
      current_time = travel_10_seconds(current_time) do
        record_100_requests(16)
        @controller.update
      end
    end

    assert_in_delta(@controller.metrics[:rejection_rate], 0.75, 0.01)
    # ----------------------------------------------------------------
    # Bring error rate back down to the ideal error rate. The rejection rate should decrease gradually.
    current_time = travel_10_seconds(current_time) do
      record_100_requests(1)
      @controller.update
      # p_value = (0.01 - 0.01) - (1/5) * 0.75 = 0 - 0.15 = -0.15
      # rejection_rate = (0.75 - 0.15)
      assert_in_delta(@controller.metrics[:rejection_rate], 0.6, 0.01)
    end

    # Should converge towards 0 in about 20 iterations
    21.times do
      current_time = travel_10_seconds(current_time) do
        record_100_requests(1)
        @controller.update
      end
    end

    assert_in_delta(@controller.metrics[:rejection_rate], 0.0, 0.01)
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
    @controller.update

    @controller.reset

    assert_equal(
      {
        rejection_rate: 0.0,
        error_rate: 0.0,
        ideal_error_rate: 0.01,
        p_value: 0.0,
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
      @controller.update

      # On the first 10 seconds, all requests are included
      assert_equal(0.5, @controller.metrics[:error_rate])
    end

    time_travel(11) do
      @controller.update

      # On the 11th second, the first second is excluded, and we're left with 1 error, so 100%
      assert_equal(1.0, @controller.metrics[:error_rate])
    end
  end

  private

  def record_100_requests(error_count)
    error_count.times do
      @controller.record_request(:error)
    end
    (100 - error_count).times do
      @controller.record_request(:success)
    end
  end

  def travel_10_seconds(start_time, &block)
    time_travel(start_time + 10) do
      block.call
    end
    start_time + 10
  end
end

class TestThreadSafeProportionalController < Minitest::Test
  include TimeHelper

  def setup
    @controller = Semian::ThreadSafe::ProportionalController.new(
      defensiveness: 5.0,
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
    @controller.update
    @controller.record_request(:error)
    @controller.should_reject?
    @controller.reset

    # If any of the above has a deadlock, the test will hang, and we'll never reach this line
    assert(true) # rubocop:disable Minitest/UselessAssertion
  end
end
