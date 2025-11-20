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
      initial_history_duration: 10000, # 10000 seconds
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
          alpha: 0.095,
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

  # def test_update_flow
  #   # Start with error rate equal to the ideal error rate (1%)
  #   (1..99).each do |_|
  #     @controller.record_request(:success)
  #   end
  #   @controller.record_request(:error)

  #   # update should maintain a rejection rate of 0
  #   @controller.update

  #   assert_equal(0, @controller.metrics[:rejection_rate])
  #   assert_in_delta(0.01, @controller.metrics[:smoother_state][:smoothed_value], 0.001)
  #   assert_equal(1, @controller.metrics[:smoother_state][:observation_count])

  #   # run another time, nothing should change
  #   (1..99).each do |_|
  #     @controller.record_request(:success)
  #   end
  #   @controller.record_request(:error)

  #   @controller.update

  #   assert_equal(0, @controller.metrics[:rejection_rate])
  #   assert_in_delta(0.01, @controller.metrics[:smoother_state][:smoothed_value], 0.001)
  #   assert_equal(2, @controller.metrics[:smoother_state][:observation_count])

  #   # Error rate now goes below the ideal error rate. Rejection rate should be unaffected.
  #   (1..100).each do |_|
  #     @controller.record_request(:success)
  #   end

  #   @controller.update

  #   assert_equal(0, @controller.metrics[:rejection_rate])
  #   assert_operator(@controller.metrics[:smoother_state][:smoothed_value], :<, 0.01)
  #   assert_equal(3, @controller.metrics[:smoother_state][:observation_count])
  #   # ------------------------------------------------------------
  #   # Error rate now goes above the ideal error rate. Rejection rate should increase.
  #   (1..92).each do |_|
  #     @controller.record_request(:success)
  #   end
  #   (1..8).each do |_|
  #     @controller.record_request(:error)
  #   end

  #   @controller.update
  #   # control signal = Ki * integral + Kp * p_value + Kd * (p_value - previous_p_value) / dt
  #   # p_value = (error_rate - ideal_error_rate) - rejection_rate = (0.08 - ~0.009) - 0 ≈ 0.071
  #   # With back-calculation anti-windup: when rejection_rate saturates (hits 0 or 1),
  #   # the integral accumulation is reversed: integral -= p_value * dt
  #   # This prevents integral windup but means the exact response depends on saturation history
  #   assert_in_delta(@controller.metrics[:rejection_rate], 0.14, 0.04)
  #   # Smoother should have moved toward higher error rate (8% is below cap so it's recorded)
  #   assert_operator(@controller.metrics[:smoother_state][:smoothed_value], :>, 0.0)
  #   assert_equal(4, @controller.metrics[:smoother_state][:observation_count])
  #   # ----------------------------------------------------------------
  #   # Maintain the same error rate (8%)
  #   (1..92).each do |_|
  #     @controller.record_request(:success)
  #   end
  #   (1..8).each do |_|
  #     @controller.record_request(:error)
  #   end
  #   @controller.update
  #   # Rejection rate should stabilize around the 8% error rate
  #   assert_in_delta(@controller.metrics[:rejection_rate], 0.08, 0.04)
  #   # Smoother continues to adapt to the 8% error rate
  #   assert_operator(@controller.metrics[:smoother_state][:smoothed_value], :>, 0.0)
  #   assert_equal(5, @controller.metrics[:smoother_state][:observation_count])
  #   # ----------------------------------------------------------------
  #   # Run a few more cycles of the same error rate. The rejection rate should fluctuate around the true error rate.
  #   10.times do
  #     (1..92).each do |_|
  #       @controller.record_request(:success)
  #     end
  #     (1..8).each do |_|
  #       @controller.record_request(:error)
  #     end
  #     @controller.update

  #     assert_in_delta(@controller.metrics[:rejection_rate], 0.08, 0.04)
  #   end
  #   assert_equal(15, @controller.metrics[:smoother_state][:observation_count])
  #   # ----------------------------------------------------------------
  #   # Bring error rate back down to the ideal error rate. The rejection rate should decrease quickly.
  #   # This is because when the rejection rate is similar to the error rate, the integral term is very small.
  #   # So the new P value dominates, bringing down the rejection rate quickly.
  #   (1..99).each do |_|
  #     @controller.record_request(:success)
  #   end
  #   @controller.record_request(:error)
  #   @controller.update

  #   assert_equal(0, @controller.metrics[:rejection_rate])
  # end

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
        previous_p_value: 0.0,
        integral: 0.0,
        derivative: 0.0,
        current_window_requests: { success: 0, error: 0, rejected: 0 },
        smoother_state: {
          smoothed_value: 0.01,
          alpha: 0.095,
          cap_value: 0.1,
          initial_value: 0.01,
          observations_per_minute: 60,
          observation_count: 0,
        },
      },
      @controller.metrics,
    )
  end

  # def test_integral_anti_windup
  #   # Test that integral doesn't accumulate when rejection_rate is saturated at 0 (low)
  #   # Simulate prolonged low error rate (below ideal)
  #   initial_integral = @controller.metrics[:integral]

  #   # Run 50 windows with 0% error rate (below ideal 1%)
  #   # With back-calculation anti-windup, integral tries to accumulate but is reversed when saturated
  #   50.times do
  #     100.times { @controller.record_request(:success) }
  #     @controller.update
  #   end

  #   # Integral should not have accumulated large negative values
  #   # because rejection_rate saturates at 0 and anti-windup reverses accumulation
  #   final_integral = @controller.metrics[:integral]

  #   assert_equal(0.0, @controller.metrics[:rejection_rate], "Rejection rate should be 0")
  #   assert_equal(initial_integral, final_integral, "Integral should not accumulate when saturated at 0")

  #   # Test that integral doesn't accumulate when rejection_rate is saturated at 1 (high)
  #   # Manually set rejection rate close to 1 and integral to simulate near-saturation
  #   @controller.instance_variable_set(:@rejection_rate, 0.95)
  #   @controller.instance_variable_set(:@integral, 5.0)

  #   # Run a window with very high error rate that would push rejection_rate above 1
  #   90.times { @controller.record_request(:error) }
  #   10.times { @controller.record_request(:success) }
  #   @controller.update

  #   # Rejection rate should be clamped at 1
  #   assert_equal(1.0, @controller.metrics[:rejection_rate], "Rejection rate should be clamped at 1")

  #   # Now run another window with same high error - integral should not accumulate further
  #   integral_at_saturation = @controller.metrics[:integral]
  #   90.times { @controller.record_request(:error) }
  #   10.times { @controller.record_request(:success) }
  #   @controller.update

  #   assert_equal(1.0, @controller.metrics[:rejection_rate], "Rejection rate should remain at 1")
  #   # Integral should not grow because anti-windup prevents accumulation when saturated
  #   assert_equal(integral_at_saturation, @controller.metrics[:integral], "Integral should not accumulate when saturated at 1")

  #   # Test that controller responds quickly to error spikes even after prolonged low-error period
  #   @controller.reset

  #   # Simulate long low error rate period (this was causing windup before the fix)
  #   20.times do
  #     100.times { @controller.record_request(:success) }
  #     @controller.update
  #   end

  #   assert_equal(0.0, @controller.metrics[:rejection_rate])
  #   assert_equal(0.0, @controller.metrics[:integral], "Integral should remain 0 due to anti-windup")

  #   # Now introduce an error spike - controller should respond immediately
  #   80.times { @controller.record_request(:success) }
  #   20.times { @controller.record_request(:error) }
  #   @controller.update

  #   # Controller should respond to the spike with proportional and derivative terms
  #   # With anti-windup, integral is 0 (not negative), so response is stronger
  #   # p_value = (0.20 - 0.01) - 0 = 0.19
  #   # control_signal = Kp*0.19 + Ki*0*dt + Kd*(0.19 - (-0.01))/dt
  #   # = 1*0.19 + 0.1*0*10 + 0.01*(0.20)/10 = 0.19 + 0 + 0.0002 ≈ 0.19
  #   # But there's also accumulated integral from previous windows, so expect higher
  #   assert_operator(@controller.metrics[:rejection_rate], :>, 0.0, "Should respond to error spike")
  #   assert_in_delta(@controller.metrics[:rejection_rate], 0.38, 0.10, "Should respond strongly to 20% error without negative integral windup")
  # end

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
end

class TestThreadSafePIDController < Minitest::Test
  include TimeHelper

  def setup
    @controller = Semian::ThreadSafe::PIDController.new(
      kp: 1.0,
      ki: 0.1,
      kd: 0.01,
      window_size: 10,
      initial_history_duration: 10000, # 10000 seconds
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
