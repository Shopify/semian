# frozen_string_literal: true

require "test_helper"
require "semian/simple_exponential_smoother"

class TestSimpleExponentialSmoother < Minitest::Test
  def setup
    @smoother = Semian::SimpleExponentialSmoother.new
  end

  # Initialization tests

  def test_initialization_with_defaults
    smoother = Semian::SimpleExponentialSmoother.new

    assert_equal(0.001, smoother.alpha)
    assert_equal(0.1, smoother.cap_value)
    assert_equal(0.01, smoother.initial_value)
    assert_equal(0.01, smoother.forecast)
  end

  def test_initialization_with_custom_params
    smoother = Semian::SimpleExponentialSmoother.new(
      initial_alpha: 0.1,
      cap_value: 0.5,
      initial_value: 0.02,
    )

    assert_equal(0.1, smoother.alpha)
    assert_equal(0.5, smoother.cap_value)
    assert_equal(0.02, smoother.initial_value)
    assert_equal(0.02, smoother.forecast)
  end

  def test_initialization_validates_alpha
    assert_raises(ArgumentError) { Semian::SimpleExponentialSmoother.new(initial_alpha: 0.0) }
    assert_raises(ArgumentError) { Semian::SimpleExponentialSmoother.new(initial_alpha: -0.1) }
    assert_raises(ArgumentError) { Semian::SimpleExponentialSmoother.new(initial_alpha: 1.5) }

    # Alpha of 1.0 should be valid
    smoother = Semian::SimpleExponentialSmoother.new(initial_alpha: 1.0)

    assert_equal(1.0, smoother.alpha)
  end

  # Core functionality tests

  def test_smoothing_formula
    smoother = Semian::SimpleExponentialSmoother.new(initial_value: 0.01, initial_alpha: 0.1)

    # First observation: smoothed = 0.1 * 0.01 + 0.9 * 0.01 = 0.01
    smoother.add_observation(0.01)

    assert_in_delta(0.01, smoother.forecast, 0.0001)

    # Second observation: smoothed = 0.1 * 0.05 + 0.9 * 0.01 = 0.014
    smoother.add_observation(0.05)

    assert_in_delta(0.014, smoother.forecast, 0.0001)
  end

  def test_add_observation_updates_smoothed_value
    initial_forecast = @smoother.forecast
    @smoother.add_observation(0.05)

    assert_operator(@smoother.forecast, :>, initial_forecast)
    assert_operator(@smoother.forecast, :<, 0.05)
  end

  def test_forecast_is_stable_and_value_is_alias
    @smoother.add_observation(0.02)
    forecast = @smoother.forecast

    # Forecast should be stable across multiple calls
    assert_equal(forecast, @smoother.forecast)
    # value is an alias
    assert_equal(@smoother.forecast, @smoother.value)
  end

  # Cap value tests

  def test_cap_value_clips_high_observations
    smoother = Semian::SimpleExponentialSmoother.new(initial_alpha: 0.2, initial_value: 0.01)

    # Add many high values (all should be capped at 0.1)
    20.times { smoother.add_observation(1.0) }

    # Should asymptotically approach cap, not the raw input value
    assert_operator(smoother.forecast, :<, 0.1)
    assert_operator(smoother.forecast, :>, 0.075)
  end

  # Critical test: 30-minute incident resilience

  def test_effect_of_30_min_incident_on_ideal_error_rate
    smoother = Semian::SimpleExponentialSmoother.new
    baseline = smoother.forecast

    # Simulate 30-minute incident (180 observations at 1 obs/min = 30 min)
    # High error rate during incident
    180.times { smoother.add_observation(0.2) }

    # We should be resilient to the incident and return close to baseline

    new_baseline = smoother.forecast

    # Should return close to baseline (within 0.01 delta as specified)
    assert_operator(new_baseline, :>, baseline)
    assert_in_delta(
      0.01,
      new_baseline,
      0.01,
      "After 30-min incident, smoother should return close to baseline",
    )
  end

  # Alpha sensitivity tests

  def test_higher_alpha_increases_recency_bias
    smoother_low = Semian::SimpleExponentialSmoother.new(initial_alpha: 0.01, initial_value: 0.01)
    smoother_high = Semian::SimpleExponentialSmoother.new(initial_alpha: 0.3, initial_value: 0.01)

    # Add same spike to both
    smoother_low.add_observation(0.15)
    smoother_high.add_observation(0.15)

    # High alpha should react more strongly
    assert_operator(smoother_high.forecast, :>, smoother_low.forecast)
  end

  # Reset tests

  def test_reset_returns_to_initial_state
    smoother = Semian::SimpleExponentialSmoother.new
    initial_forecast = smoother.forecast

    # Change state
    50.times { smoother.add_observation(0.1) }

    assert_operator(smoother.forecast, :>, initial_forecast)

    # Reset should return to initial state
    result = smoother.reset

    assert_equal(smoother, result) # Should allow method chaining
    assert_equal(initial_forecast, smoother.forecast)
  end

  # Edge cases

  def test_handles_edge_case_values
    smoother = Semian::SimpleExponentialSmoother.new

    # Zero observation
    smoother.add_observation(0.0)

    assert_operator(smoother.forecast, :<, 0.01)

    # Negative observation (shouldn't crash)
    smoother.add_observation(-0.1)

    assert_operator(smoother.forecast, :<, 0.01)

    # Many stable observations
    smoother.reset
    1000.times { smoother.add_observation(0.01) }

    assert_in_delta(0.01, smoother.forecast, 0.0001)
  end
end
