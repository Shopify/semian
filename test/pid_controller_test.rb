# frozen_string_literal: true

require "test_helper"
require "semian/pid_controller"

class TestPIDController < Minitest::Test
  include TimeHelper

  def setup
    Process.stubs(:clock_gettime).with(Process::CLOCK_MONOTONIC).returns(1000)
    @controller = Semian::PIDController.new(
      kp: 1.0,
      ki: 0.1,
      kd: 0.01,
      window_size: 10,
      initial_history_duration: 10000, # 10000 seconds
      initial_error_rate: 0.01,
    )
  end

  def teardown
    @controller.reset
    Process.unstub(:clock_gettime)
  end

  def test_initial_values
    metrics = @controller.metrics

    assert_equal(
      {
        rejection_rate: 0.0,
        error_rate: 0.0,
        ideal_error_rate: 0.01, # Default when no history
        p_value: 0.0,
        integral: 0.0,
        previous_p_value: 0.0,
        derivative: 0.0,
        current_window_requests: { success: 0, error: 0, rejected: 0 },
        p90_estimator_state: {
          # Initialization prefills with initial_history_duration/window_size observations = 20, all 0.01
          observations: 1000,
          markers: [0.01] * 5,
          # The positions are of P0, P45, P90, P95, P100 of 1000 observations
          positions: [0, 449, 899, 949, 999],
          quantile: 0.9,
        },
      },
      metrics,
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
    (1..99).each do |_|
      @controller.record_request(:success)
    end
    @controller.record_request(:error)

    # update should maintain a rejection rate of 0
    @controller.update

    assert_equal(0, @controller.metrics[:rejection_rate])
    # update should add a new observation to the p90 estimator
    assert_equal(1001, @controller.metrics[:p90_estimator_state][:observations])
    # ------------------------------------------------------------
    # run another time, nothing should change
    (1..99).each do |_|
      @controller.record_request(:success)
    end
    @controller.record_request(:error)

    @controller.update

    assert_equal(0, @controller.metrics[:rejection_rate])
    assert_equal(1002, @controller.metrics[:p90_estimator_state][:observations])
    # ------------------------------------------------------------
    # Error rate now goes below the ideal error rate. Rejection rate should be unaffected.
    (1..100).each do |_|
      @controller.record_request(:success)
    end

    @controller.update

    assert_equal(0, @controller.metrics[:rejection_rate])
    assert_equal(1003, @controller.metrics[:p90_estimator_state][:observations])
    # ------------------------------------------------------------
    # Error rate now goes above the ideal error rate. Rejection rate should increase.
    (1..89).each do |_|
      @controller.record_request(:success)
    end
    (1..11).each do |_|
      @controller.record_request(:error)
    end

    @controller.update
    # control signal = Ki * integral + Kp * p_value + Kd * (p_value - previous_p_value) / dt
    # p_value = (error_rate - ideal_error_rate) - rejection_rate = (0.11 - 0.01) - 0 = 0.1
    # = 0.1 * (-0.01+ 0.1) * 10 + 1 * 0.1 + 0.01 * (0.1 - (-0.01)) / 10 = 0.19011
    # rejection rate = 0 + 0.19011 = 0.19011
    assert_in_delta(@controller.metrics[:rejection_rate], 0.19, 0.01)
    assert_equal(1004, @controller.metrics[:p90_estimator_state][:observations])
    # ----------------------------------------------------------------
    # Maintain the same error rate
    (1..89).each do |_|
      @controller.record_request(:success)
    end
    (1..11).each do |_|
      @controller.record_request(:error)
    end
    @controller.update
    # control signal = Ki * integral + Kp * p_value + Kd * (p_value - previous_p_value) / dt
    # p_value = (error_rate - ideal_error_rate) - rejection_rate = (0.11 - 0.01) - 0.19011 = -0.09011
    # = 0.1 * (-0.01+ 0.1 -0.09011) * 10 + 1 * -0.09011 + 0.01 * (-0.09011 - (0.19011)) / 10 = -0.09050022
    # rejection rate = 0.19011 - 0.09050022 = 0.09960978
    assert_in_delta(@controller.metrics[:rejection_rate], 0.11, 0.02)
    assert_equal(1005, @controller.metrics[:p90_estimator_state][:observations])
    # ----------------------------------------------------------------
    # Run a few more cycles of the same error rate. The rejection rate should fluctuate around the true error rate.
    (1..10).each do |j|
      (1..89).each do |_|
        @controller.record_request(:success)
      end
      (1..11).each do |_|
        @controller.record_request(:error)
      end
      @controller.update

      assert_in_delta(@controller.metrics[:rejection_rate], 0.11, 0.02)
      assert_equal(@controller.metrics[:p90_estimator_state][:observations], 1005 + j)
    end
    # ----------------------------------------------------------------
    # Bring error rate back down to the ideal error rate. The rejection rate should decrease quickly.
    # This is because when the rejection rate is similar to the error rate, the integral term is very small.
    # So the new P value dominates, bringing down the rejection rate quickly.
    (1..99).each do |_|
      @controller.record_request(:success)
    end
    @controller.record_request(:error)
    @controller.update

    assert_equal(0, @controller.metrics[:rejection_rate])
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
        ideal_error_rate: 0.01, # Default when no history
        p_value: 0.0,
        integral: 0.0,
        previous_p_value: 0.0,
        derivative: 0.0,
        current_window_requests: { success: 0, error: 0, rejected: 0 },
        p90_estimator_state: {
          # Initialization prefills with initial_history_duration/window_size observations = 20, all 0.01
          observations: 1000,
          markers: [0.01] * 5,
          # The positions are of P0, P45, P90, P95, P100 of 1000 observations
          positions: [0, 449, 899, 949, 999],
          quantile: 0.9,
        },
      },
      @controller.metrics,
    )
  end

  def test_ideal_error_rate_never_returns_more_than_10
    estimator = @controller.instance_variable_get(:@p90_estimator)
    estimator.reset
    (1..1000).each do |_|
      estimator.add_observation(0.5)
    end

    assert_equal(0.1, @controller.metrics[:ideal_error_rate])
  end

  def test_integral_anti_windup
    # Test that integral doesn't accumulate when rejection_rate is saturated at 0 (low)
    # Simulate prolonged low error rate (below ideal)
    initial_integral = @controller.metrics[:integral]

    # Run 50 windows with 0% error rate (below ideal 1%)
    50.times do
      100.times { @controller.record_request(:success) }
      @controller.update
    end

    # Integral should not have accumulated large negative values
    # because rejection_rate should stay at 0 (saturated low)
    final_integral = @controller.metrics[:integral]

    assert_equal(0.0, @controller.metrics[:rejection_rate], "Rejection rate should be 0")
    assert_equal(initial_integral, final_integral, "Integral should not accumulate when rejection_rate = 0")

    # Test that integral doesn't accumulate when rejection_rate is saturated at 1 (high)
    # Manually set rejection rate to 1 to simulate saturation
    @controller.instance_variable_set(:@rejection_rate, 1.0)
    @controller.instance_variable_set(:@integral, 5.0)
    initial_integral_high = @controller.metrics[:integral]

    # Run a window with high error rate
    50.times { @controller.record_request(:error) }
    50.times { @controller.record_request(:success) }
    @controller.update

    # Integral should not have accumulated more
    final_integral_high = @controller.metrics[:integral]

    assert_equal(1.0, @controller.metrics[:rejection_rate], "Rejection rate should be 1")
    assert_equal(initial_integral_high, final_integral_high, "Integral should not accumulate when rejection_rate = 1")

    # Test that controller responds quickly to error spikes even after no integral accumulation
    @controller.reset

    # Simulate low error rate without integral accumulation (rejection_rate stays at 0)
    20.times do
      100.times { @controller.record_request(:success) }
      @controller.update
    end

    assert_equal(0.0, @controller.metrics[:rejection_rate])
    assert_equal(0.0, @controller.metrics[:integral], "Integral should remain 0")

    # Now introduce an error spike
    80.times { @controller.record_request(:success) }
    20.times { @controller.record_request(:error) }
    @controller.update

    # Controller should respond to the spike with proportional and derivative terms
    # even though integral hasn't accumulated
    assert_operator(@controller.metrics[:rejection_rate], :>, 0.0, "Should respond to error spike")
    assert_in_delta(@controller.metrics[:rejection_rate], 0.19, 0.05, "Should respond proportionally to 20% error")
  end
end

class TestThreadSafePIDController < Minitest::Test
  include TimeHelper

  def setup
    @controller = Semian::ThreadSafePIDController.new(
      kp: 1.0,
      ki: 0.1,
      kd: 0.01,
      window_size: 10,
      initial_history_duration: 10000, # 10000 seconds
      initial_error_rate: 0.01,
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
