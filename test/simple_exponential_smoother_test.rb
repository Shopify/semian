# frozen_string_literal: true

require "test_helper"
require "semian/simple_exponential_smoother"

class TestSimpleExponentialSmoother < Minitest::Test
  private

  def simulate_observations(smoother, error_rate, count)
    count.times { smoother.add_observation(error_rate) }
  end

  public

  def test_initialization_with_defaults
    smoother = Semian::SimpleExponentialSmoother.new(initial_value: 0.05, observations_per_minute: 60)

    # Alpha starts at LOW_CONFIDENCE_ALPHA_DOWN
    assert_equal(0.078, smoother.alpha)
    assert_equal(0.1, smoother.cap_value)
    assert_equal(0.05, smoother.initial_value)
    assert_equal(0.05, smoother.forecast)
  end

  def test_initialization_with_custom_params
    smoother = Semian::SimpleExponentialSmoother.new(
      cap_value: 0.5,
      initial_value: 0.02,
      observations_per_minute: 60,
    )

    # Alpha starts at LOW_CONFIDENCE_ALPHA_DOWN
    assert_equal(0.078, smoother.alpha)
    assert_equal(0.5, smoother.cap_value)
    assert_equal(0.02, smoother.initial_value)
    assert_equal(0.02, smoother.forecast)
  end

  def test_smoothing_formula
    smoother = Semian::SimpleExponentialSmoother.new(initial_value: 0.01, observations_per_minute: 60)

    smoother.add_observation(0.01)

    assert_in_delta(0.01, smoother.forecast, 0.001)

    smoother.add_observation(0.05)

    # Converging up in low confidence: alpha = 0.0017
    # Expected: 0.0017 * 0.05 + 0.9983 * 0.01 = 0.010068
    assert_in_delta(0.010068, smoother.forecast, 0.0001)
  end

  def test_add_observation_updates_smoothed_value
    smoother = Semian::SimpleExponentialSmoother.new(initial_value: 0.05, observations_per_minute: 60)

    initial_forecast = smoother.forecast
    smoother.add_observation(0.08)

    assert_operator(smoother.forecast, :>, initial_forecast)
    assert_operator(smoother.forecast, :<, 0.08)
  end

  def test_cap_value_drops_high_observations
    smoother = Semian::SimpleExponentialSmoother.new(initial_value: 0.01, observations_per_minute: 60)
    initial_forecast = smoother.forecast

    20.times { smoother.add_observation(1.0) }

    assert_equal(initial_forecast, smoother.forecast)

    20.times { smoother.add_observation(0.05) }

    assert_operator(smoother.forecast, :>, initial_forecast)
  end

  def test_adaptive_alpha_based_on_direction
    smoother = Semian::SimpleExponentialSmoother.new(initial_value: 0.01, observations_per_minute: 60)

    smoother.add_observation(0.08)

    # Converging up in low confidence: alpha = 0.0017
    assert_equal(0.0017, smoother.alpha)
    # Expected: 0.0017 * 0.08 + 0.9983 * 0.01 = 0.010119
    assert_in_delta(0.010119, smoother.forecast, 0.0001)
  end

  def test_reset_returns_to_initial_state
    smoother = Semian::SimpleExponentialSmoother.new(initial_value: 0.05, observations_per_minute: 60)
    initial_forecast = smoother.forecast

    50.times { smoother.add_observation(0.1) }

    assert_operator(smoother.forecast, :>, initial_forecast)

    result = smoother.reset

    assert_equal(smoother, result)
    assert_equal(initial_forecast, smoother.forecast)
  end

  def test_alpha_changes_with_confidence_period
    smoother = Semian::SimpleExponentialSmoother.new(initial_value: 0.01, observations_per_minute: 60)

    smoother.add_observation(0.08)
    low_confidence_alpha = smoother.alpha

    1800.times { smoother.add_observation(0.01) }

    smoother.add_observation(0.08)
    high_confidence_alpha = smoother.alpha

    assert_operator(high_confidence_alpha, :<, low_confidence_alpha)
  end

  def test_handles_edge_case_values
    smoother = Semian::SimpleExponentialSmoother.new(initial_value: 0.05, observations_per_minute: 60)

    initial_value = smoother.forecast
    smoother.add_observation(0.0)

    assert_operator(smoother.forecast, :<, initial_value)

    assert_raises(ArgumentError) { smoother.add_observation(-0.1) }

    smoother.reset
    1000.times { smoother.add_observation(0.05) }

    assert_in_delta(0.05, smoother.forecast, 0.0001)
  end
end
