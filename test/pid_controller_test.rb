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

    assert_equal(0.0, metrics[:rejection_rate])
    assert_equal(0.0, metrics[:error_rate])
    assert_equal(0.01, metrics[:ideal_error_rate])
    assert_equal(0.0, metrics[:p_value])
    assert_equal(0.0, metrics[:previous_p_value])
    assert_equal(0.0, metrics[:integral])
    assert_equal(0.0, metrics[:derivative])
    assert_equal({ success: 0, error: 0, rejected: 0 }, metrics[:current_window_requests])

    # Smoother state checks
    smoother_state = metrics[:smoother_state]

    assert_equal(0.01, smoother_state[:smoothed_value])
    assert_equal(0.001, smoother_state[:alpha])
    assert_equal(0.001, smoother_state[:initial_alpha])
    assert_equal(0.1, smoother_state[:cap_value])
    assert_equal(0.01, smoother_state[:initial_value])
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
    # update should update the smoother with new observation
    assert_in_delta(0.01, @controller.metrics[:smoother_state][:smoothed_value], 0.001)
    # ------------------------------------------------------------
    # run another time, nothing should change
    (1..99).each do |_|
      @controller.record_request(:success)
    end
    @controller.record_request(:error)

    @controller.update

    assert_equal(0, @controller.metrics[:rejection_rate])
    assert_in_delta(0.01, @controller.metrics[:smoother_state][:smoothed_value], 0.001)
    # ------------------------------------------------------------
    # Error rate now goes below the ideal error rate. Rejection rate should be unaffected.
    (1..100).each do |_|
      @controller.record_request(:success)
    end

    @controller.update

    assert_equal(0, @controller.metrics[:rejection_rate])
    # Smoother should have moved slightly toward 0 error rate
    assert_operator(@controller.metrics[:smoother_state][:smoothed_value], :<, 0.01)
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
    # With back-calculation anti-windup: when rejection_rate saturates (hits 0 or 1),
    # the integral accumulation is reversed: integral -= p_value * dt
    # This prevents integral windup but means the exact response depends on saturation history
    assert_in_delta(@controller.metrics[:rejection_rate], 0.20, 0.02)
    # Smoother should have moved toward higher error rate
    assert_operator(@controller.metrics[:smoother_state][:smoothed_value], :>, 0.01)
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
    # Smoother continues to adapt to the 11% error rate
    assert_operator(@controller.metrics[:smoother_state][:smoothed_value], :>, 0.01)
    # ----------------------------------------------------------------
    # Run a few more cycles of the same error rate. The rejection rate should fluctuate around the true error rate.
    10.times do
      (1..89).each do |_|
        @controller.record_request(:success)
      end
      (1..11).each do |_|
        @controller.record_request(:error)
      end
      @controller.update

      assert_in_delta(@controller.metrics[:rejection_rate], 0.11, 0.02)
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

    metrics = @controller.metrics

    assert_equal(0.0, metrics[:rejection_rate])
    assert_equal(0.0, metrics[:error_rate])
    assert_equal(0.01, metrics[:ideal_error_rate])
    assert_equal(0.0, metrics[:p_value])
    assert_equal(0.0, metrics[:previous_p_value])
    assert_equal(0.0, metrics[:integral])
    assert_equal(0.0, metrics[:derivative])
    assert_equal({ success: 0, error: 0, rejected: 0 }, metrics[:current_window_requests])

    # Smoother state should be reset to initial values
    smoother_state = metrics[:smoother_state]

    assert_equal(0.01, smoother_state[:smoothed_value])
    assert_equal(0.001, smoother_state[:alpha])
    assert_equal(0.001, smoother_state[:initial_alpha])
    assert_equal(0.1, smoother_state[:cap_value])
    assert_equal(0.01, smoother_state[:initial_value])
  end

  def test_ideal_error_rate_never_returns_more_than_10
    # Create a smoother with higher alpha to ensure it converges faster for this test
    custom_controller = Semian::PIDController.new(
      kp: 1.0,
      ki: 0.1,
      kd: 0.01,
      window_size: 10,
      initial_history_duration: 100,
      initial_error_rate: 0.01,
      smoother_alpha: 0.1, # Higher alpha for faster convergence
    )

    smoother = custom_controller.instance_variable_get(:@smoother)

    # Add high error rate observations - smoother will cap them at 0.1
    # With higher alpha, it should converge quickly
    (1..100).each do |_|
      smoother.add_observation(0.5)
    end

    # After convergence, forecast should be close to cap (0.1)
    # and calculate_ideal_error_rate should cap it at 0.1
    assert_operator(custom_controller.metrics[:ideal_error_rate], :<, 0.1)
    assert_in_delta(0.1, custom_controller.metrics[:ideal_error_rate], 0.001)
  end

  def test_integral_anti_windup
    # Test that integral doesn't accumulate when rejection_rate is saturated at 0 (low)
    # Simulate prolonged low error rate (below ideal)
    initial_integral = @controller.metrics[:integral]

    # Run 50 windows with 0% error rate (below ideal 1%)
    # With back-calculation anti-windup, integral tries to accumulate but is reversed when saturated
    50.times do
      100.times { @controller.record_request(:success) }
      @controller.update
    end

    # Integral should not have accumulated large negative values
    # because rejection_rate saturates at 0 and anti-windup reverses accumulation
    final_integral = @controller.metrics[:integral]

    assert_equal(0.0, @controller.metrics[:rejection_rate], "Rejection rate should be 0")
    assert_equal(initial_integral, final_integral, "Integral should not accumulate when saturated at 0")

    # Test that integral doesn't accumulate when rejection_rate is saturated at 1 (high)
    # Manually set rejection rate close to 1 and integral to simulate near-saturation
    @controller.instance_variable_set(:@rejection_rate, 0.95)
    @controller.instance_variable_set(:@integral, 5.0)

    # Run a window with very high error rate that would push rejection_rate above 1
    90.times { @controller.record_request(:error) }
    10.times { @controller.record_request(:success) }
    @controller.update

    # Rejection rate should be clamped at 1
    assert_equal(1.0, @controller.metrics[:rejection_rate], "Rejection rate should be clamped at 1")

    # Now run another window with same high error - integral should not accumulate further
    integral_at_saturation = @controller.metrics[:integral]
    90.times { @controller.record_request(:error) }
    10.times { @controller.record_request(:success) }
    @controller.update

    assert_equal(1.0, @controller.metrics[:rejection_rate], "Rejection rate should remain at 1")
    # Integral should not grow because anti-windup prevents accumulation when saturated
    assert_equal(integral_at_saturation, @controller.metrics[:integral], "Integral should not accumulate when saturated at 1")

    # Test that controller responds quickly to error spikes even after prolonged low-error period
    @controller.reset

    # Simulate long low error rate period (this was causing windup before the fix)
    20.times do
      100.times { @controller.record_request(:success) }
      @controller.update
    end

    assert_equal(0.0, @controller.metrics[:rejection_rate])
    assert_equal(0.0, @controller.metrics[:integral], "Integral should remain 0 due to anti-windup")

    # Now introduce an error spike - controller should respond immediately
    80.times { @controller.record_request(:success) }
    20.times { @controller.record_request(:error) }
    @controller.update

    # Controller should respond to the spike with proportional and derivative terms
    # With anti-windup, integral is 0 (not negative), so response is stronger
    # p_value = (0.20 - 0.01) - 0 = 0.19
    # control_signal = Kp*0.19 + Ki*0*dt + Kd*(0.19 - (-0.01))/dt
    # = 1*0.19 + 0.1*0*10 + 0.01*(0.20)/10 = 0.19 + 0 + 0.0002 ≈ 0.19
    # But there's also accumulated integral from previous windows, so expect higher
    assert_operator(@controller.metrics[:rejection_rate], :>, 0.0, "Should respond to error spike")
    assert_in_delta(@controller.metrics[:rejection_rate], 0.38, 0.10, "Should respond strongly to 20% error without negative integral windup")
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
