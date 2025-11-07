# frozen_string_literal: true

require "test_helper"
require "semian/simple_exponential_smoother"

class TestSimpleExponentialSmoother < Minitest::Test
  def setup
    @smoother = Semian::SimpleExponentialSmoother.new
  end

  # Basic functionality tests

  def test_initialization_with_defaults
    smoother = Semian::SimpleExponentialSmoother.new

    assert_equal(0.05, smoother.alpha)
    assert_equal(0.2, smoother.cap_value)
    assert_equal(0.01, smoother.prefill_value)

    # After prefill, smoothed value should be very close to prefill_value
    assert_in_delta(0.01, smoother.forecast, 0.0001)
  end

  def test_initialization_with_custom_params
    smoother = Semian::SimpleExponentialSmoother.new(
      alpha: 0.1,
      cap_value: 0.5,
      prefill_value: 0.02,
      prefill_count: 30,
    )

    assert_equal(0.1, smoother.alpha)
    assert_equal(0.5, smoother.cap_value)
    assert_equal(0.02, smoother.prefill_value)
    assert_in_delta(0.02, smoother.forecast, 0.0001)
  end

  def test_initialization_validates_alpha_too_low
    error = assert_raises(ArgumentError) do
      Semian::SimpleExponentialSmoother.new(alpha: 0.0)
    end
    assert_match(/alpha must be in range \(0, 1\]/, error.message)
  end

  def test_initialization_validates_alpha_negative
    error = assert_raises(ArgumentError) do
      Semian::SimpleExponentialSmoother.new(alpha: -0.1)
    end
    assert_match(/alpha must be in range \(0, 1\]/, error.message)
  end

  def test_initialization_validates_alpha_too_high
    error = assert_raises(ArgumentError) do
      Semian::SimpleExponentialSmoother.new(alpha: 1.5)
    end
    assert_match(/alpha must be in range \(0, 1\]/, error.message)
  end

  def test_alpha_of_one_is_valid
    smoother = Semian::SimpleExponentialSmoother.new(alpha: 1.0)

    assert_equal(1.0, smoother.alpha)
  end

  # Core smoothing functionality tests

  def test_add_observation_updates_smoothed_value
    initial_forecast = @smoother.forecast
    @smoother.add_observation(0.05)

    # With low alpha (0.05), the smoothed value should move slightly toward 0.05
    assert_operator(@smoother.forecast, :>, initial_forecast)
    assert_operator(@smoother.forecast, :<, 0.05)
  end

  def test_forecast_returns_current_smoothed_value
    @smoother.add_observation(0.02)
    forecast = @smoother.forecast

    # Calling forecast multiple times should return the same value
    assert_equal(forecast, @smoother.forecast)
    assert_equal(forecast, @smoother.forecast)
  end

  def test_value_alias_returns_smoothed_value
    @smoother.add_observation(0.03)

    assert_equal(@smoother.forecast, @smoother.value)
  end

  def test_smoothing_formula_with_simple_sequence
    # Start fresh with no prefill to test formula directly
    smoother = Semian::SimpleExponentialSmoother.new(prefill_count: 0, alpha: 0.1)

    # First observation: smoothed = 0.1 * 0.01 + 0.9 * 0.01 = 0.01
    smoother.add_observation(0.01)

    assert_in_delta(0.01, smoother.forecast, 0.0001)

    # Second observation: smoothed = 0.1 * 0.05 + 0.9 * 0.01 = 0.014
    smoother.add_observation(0.05)

    assert_in_delta(0.014, smoother.forecast, 0.0001)
  end

  # Capping and clipping tests

  def test_cap_value_clips_high_observations
    initial_forecast = @smoother.forecast

    # Add observation well above cap
    @smoother.add_observation(0.9)

    # Smoothed value should move toward cap_value (0.2), not 0.9
    new_forecast = @smoother.forecast

    assert_operator(new_forecast, :>, initial_forecast)

    # With alpha=0.05: new_smoothed ≈ 0.05 * 0.2 + 0.95 * 0.01 ≈ 0.0195
    assert_in_delta(0.0195, new_forecast, 0.001)
  end

  def test_observations_below_cap_not_affected
    initial_forecast = @smoother.forecast

    # Add observation below cap
    @smoother.add_observation(0.05)

    # Should move smoothly toward 0.05
    new_forecast = @smoother.forecast

    assert_operator(new_forecast, :>, initial_forecast)
    assert_operator(new_forecast, :<, 0.05)
  end

  def test_multiple_high_values_respect_cap
    smoother = Semian::SimpleExponentialSmoother.new(alpha: 0.2, prefill_count: 10)

    # Add many high values (all should be capped at 0.2)
    20.times { smoother.add_observation(1.0) }

    # With alpha=0.2 and cap=0.2, should asymptotically approach 0.2
    # After many iterations, should be close to cap
    assert_operator(smoother.forecast, :<, 0.2)
    assert_operator(smoother.forecast, :>, 0.15)
  end

  # Low recency bias tests

  def test_low_recency_bias_single_spike
    # Start with stable baseline
    smoother = Semian::SimpleExponentialSmoother.new(alpha: 0.05)
    baseline_before = smoother.forecast

    # Single spike
    smoother.add_observation(0.15)
    after_spike = smoother.forecast

    # Should move only slightly
    movement = after_spike - baseline_before

    assert_operator(movement, :>, 0)
    assert_operator(movement, :<, 0.01) # Very small movement due to low alpha
  end

  def test_low_recency_bias_returns_to_baseline_after_spike
    smoother = Semian::SimpleExponentialSmoother.new(alpha: 0.05)

    # Add a spike
    smoother.add_observation(0.15)
    after_spike = smoother.forecast

    # Add many low observations
    50.times { smoother.add_observation(0.01) }
    after_recovery = smoother.forecast

    # Should return close to baseline
    assert_operator(after_recovery, :<, after_spike)
    assert_in_delta(0.01, after_recovery, 0.002)
  end

  def test_gradual_adaptation_to_sustained_change
    smoother = Semian::SimpleExponentialSmoother.new(alpha: 0.05)
    baseline = smoother.forecast

    # Sustained increase to 0.05
    100.times { smoother.add_observation(0.05) }

    # Should gradually move toward 0.05
    new_baseline = smoother.forecast

    assert_operator(new_baseline, :>, baseline)
    assert_in_delta(0.05, new_baseline, 0.01)
  end

  # Critical test: 30-minute incident resilience

  def test_effect_of_30_min_incident_on_ideal_error_rate
    smoother = Semian::SimpleExponentialSmoother.new

    # Simulate 30-minute incident (180 observations at 1 obs/min = 30 min)
    # High error rate during incident
    180.times { smoother.add_observation(0.2) }

    # Post-incident recovery (120 observations = 20 min)
    120.times { smoother.add_observation(0.01) }

    after_recovery = smoother.forecast

    # Should return close to baseline (within 0.01 delta as specified)
    assert_in_delta(
      0.01,
      after_recovery,
      0.01,
      "After 30-min incident and 20-min recovery, smoother should return close to baseline",
    )
  end

  # Alpha sensitivity tests

  def test_higher_alpha_increases_recency_bias
    smoother_low = Semian::SimpleExponentialSmoother.new(alpha: 0.05, prefill_count: 30)
    smoother_high = Semian::SimpleExponentialSmoother.new(alpha: 0.3, prefill_count: 30)

    # Add same spike to both
    smoother_low.add_observation(0.15)
    smoother_high.add_observation(0.15)

    # High alpha should react more strongly
    assert_operator(smoother_high.forecast, :>, smoother_low.forecast)
  end

  def test_lower_alpha_provides_more_stability
    smoother_low = Semian::SimpleExponentialSmoother.new(alpha: 0.01, prefill_count: 20)
    smoother_high = Semian::SimpleExponentialSmoother.new(alpha: 0.2, prefill_count: 20)

    initial_low = smoother_low.forecast
    initial_high = smoother_high.forecast

    # Add several moderate spikes
    5.times do
      smoother_low.add_observation(0.1)
      smoother_high.add_observation(0.1)
    end

    change_low = smoother_low.forecast - initial_low
    change_high = smoother_high.forecast - initial_high

    # Low alpha should change less
    assert_operator(change_low, :<, change_high)
  end

  # Prefill behavior tests

  def test_prefill_establishes_baseline
    smoother = Semian::SimpleExponentialSmoother.new(
      prefill_value: 0.03,
      prefill_count: 40,
    )

    # After prefill, should be at prefill_value
    assert_in_delta(0.03, smoother.forecast, 0.0001)
  end

  def test_zero_prefill_count_starts_at_prefill_value
    smoother = Semian::SimpleExponentialSmoother.new(
      prefill_value: 0.02,
      prefill_count: 0,
    )

    # Should start exactly at prefill_value without any smoothing
    assert_equal(0.02, smoother.forecast)
  end

  def test_different_prefill_values
    smoother_low = Semian::SimpleExponentialSmoother.new(prefill_value: 0.005)
    smoother_high = Semian::SimpleExponentialSmoother.new(prefill_value: 0.05)

    # Should maintain different baselines
    assert_operator(smoother_low.forecast, :<, smoother_high.forecast)
    assert_in_delta(0.005, smoother_low.forecast, 0.0001)
    assert_in_delta(0.05, smoother_high.forecast, 0.0001)
  end

  # Reset functionality tests

  def test_reset_returns_to_initial_state
    smoother = Semian::SimpleExponentialSmoother.new
    initial_forecast = smoother.forecast

    # Add observations to change state
    50.times { smoother.add_observation(0.1) }

    assert_operator(smoother.forecast, :>, initial_forecast)

    # Reset
    smoother.reset

    # Should return to initial state
    assert_in_delta(initial_forecast, smoother.forecast, 0.0001)
  end

  def test_reset_allows_method_chaining
    smoother = Semian::SimpleExponentialSmoother.new
    result = smoother.reset

    assert_equal(smoother, result)
  end

  # Edge cases and robustness tests

  def test_handles_zero_observations
    smoother = Semian::SimpleExponentialSmoother.new

    # Add zero value
    smoother.add_observation(0.0)

    # Should decrease smoothed value toward zero
    assert_operator(smoother.forecast, :<, 0.01)
  end

  def test_handles_exact_cap_value
    smoother = Semian::SimpleExponentialSmoother.new

    smoother.add_observation(0.2) # Exactly at cap

    # Should work without issues
    assert_operator(smoother.forecast, :>, 0.01)
    assert_operator(smoother.forecast, :<, 0.2)
  end

  def test_handles_negative_observations_gracefully
    smoother = Semian::SimpleExponentialSmoother.new

    # Add negative value (though not expected in real usage)
    smoother.add_observation(-0.1)

    # Should decrease smoothed value
    assert_operator(smoother.forecast, :<, 0.01)
  end

  def test_many_observations_remain_stable
    smoother = Semian::SimpleExponentialSmoother.new

    # Add many observations at baseline
    1000.times { smoother.add_observation(0.01) }

    # Should remain stable at baseline
    assert_in_delta(0.01, smoother.forecast, 0.0001)
  end

  # Practical scenario tests

  def test_short_5_min_incident_minimal_impact
    smoother = Semian::SimpleExponentialSmoother.new
    baseline_before = smoother.forecast

    # 5-minute incident (5 observations)
    5.times { smoother.add_observation(0.2) }

    # 50-minute recovery (realistic for low alpha=0.05)
    50.times { smoother.add_observation(0.01) }

    after_recovery = smoother.forecast

    # Short incident should have minimal lasting impact after sufficient recovery time
    # With alpha=0.05 (low recency bias), recovery is intentionally slow but steady
    assert_in_delta(baseline_before, after_recovery, 0.005)
  end

  def test_gradual_degradation_is_tracked
    smoother = Semian::SimpleExponentialSmoother.new

    # Gradual increase from 0.01 to 0.05 over 100 observations
    100.times do |i|
      value = 0.01 + (0.04 * i / 100.0)
      smoother.add_observation(value)
    end

    # Should adapt to new higher baseline
    assert_operator(smoother.forecast, :>, 0.03)
    assert_operator(smoother.forecast, :<, 0.06)
  end

  def test_oscillating_values_are_smoothed
    smoother = Semian::SimpleExponentialSmoother.new(alpha: 0.1)

    # Oscillate between low and moderate values
    20.times do |i|
      value = i.even? ? 0.01 : 0.08
      smoother.add_observation(value)
    end

    # Should converge to somewhere in the middle
    forecast = smoother.forecast

    assert_operator(forecast, :>, 0.01)
    assert_operator(forecast, :<, 0.08)

    # Should be relatively stable despite oscillation
    assert_in_delta(0.045, forecast, 0.02)
  end

  def test_realistic_error_rate_sequence
    smoother = Semian::SimpleExponentialSmoother.new

    # Normal operation: low error rates
    60.times { smoother.add_observation(0.005 + rand * 0.005) }
    normal_baseline = smoother.forecast

    # Brief spike
    10.times { smoother.add_observation(0.15) }

    # Return to normal
    60.times { smoother.add_observation(0.005 + rand * 0.005) }
    recovered_baseline = smoother.forecast

    # Should return close to original baseline
    assert_in_delta(normal_baseline, recovered_baseline, 0.005)
  end

  # Integration-style test simulating real usage

  def test_use_as_baseline_for_comparison
    smoother = Semian::SimpleExponentialSmoother.new

    # Establish baseline
    50.times { smoother.add_observation(0.01) }
    baseline = smoother.forecast

    # New observation significantly above baseline
    current_error_rate = 0.08

    # Can use forecast to determine if current rate is anomalous
    deviation_ratio = current_error_rate / baseline

    assert_operator(deviation_ratio, :>, 5, "Current error rate should be significantly above smoothed baseline")
  end

  def test_adaptation_speed_with_different_alphas
    alpha_values = [0.01, 0.05, 0.1, 0.3]
    final_forecasts = []

    alpha_values.each do |alpha|
      smoother = Semian::SimpleExponentialSmoother.new(alpha: alpha, prefill_count: 20)

      # Add sustained higher rate
      50.times { smoother.add_observation(0.08) }

      final_forecasts << smoother.forecast
    end

    # Higher alphas should result in higher final forecasts (faster adaptation)
    assert_operator(final_forecasts[0], :<, final_forecasts[1])
    assert_operator(final_forecasts[1], :<, final_forecasts[2])
    assert_operator(final_forecasts[2], :<, final_forecasts[3])
  end
end
