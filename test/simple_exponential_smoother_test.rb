# frozen_string_literal: true

require "test_helper"
require "semian/simple_exponential_smoother"

class TestSimpleExponentialSmoother < Minitest::Test
  def setup
    @smoother = Semian::SimpleExponentialSmoother.new
  end

  private

  def simulate_observations(smoother, error_rate, count)
    count.times { smoother.add_observation(error_rate) }
  end

  public

  def test_initialization_with_defaults
    smoother = Semian::SimpleExponentialSmoother.new

    assert_equal(0.001, smoother.alpha)
    assert_equal(0.1, smoother.cap_value)
    assert_equal(0.05, smoother.initial_value)
    assert_equal(0.05, smoother.forecast)
  end

  def test_initialization_with_custom_params
    smoother = Semian::SimpleExponentialSmoother.new(
      cap_value: 0.5,
      initial_value: 0.02,
    )

    assert_equal(0.001, smoother.alpha)
    assert_equal(0.5, smoother.cap_value)
    assert_equal(0.02, smoother.initial_value)
    assert_equal(0.02, smoother.forecast)
  end

  def test_initialization_validates_alpha
    assert_raises(ArgumentError) { Semian::SimpleExponentialSmoother.new(initial_alpha: 0.0) }
    assert_raises(ArgumentError) { Semian::SimpleExponentialSmoother.new(initial_alpha: -0.1) }
    assert_raises(ArgumentError) { Semian::SimpleExponentialSmoother.new(initial_alpha: 0.5) }
    assert_raises(ArgumentError) { Semian::SimpleExponentialSmoother.new(initial_alpha: 1.5) }

    smoother = Semian::SimpleExponentialSmoother.new(initial_alpha: 0.49)

    assert_equal(0.49, smoother.alpha)
  end

  def test_smoothing_formula
    smoother = Semian::SimpleExponentialSmoother.new(initial_value: 0.01)

    smoother.add_observation(0.01)

    assert_in_delta(0.01, smoother.forecast, 0.001)

    smoother.add_observation(0.05)

    # Converging up in low confidence: alpha = 0.017
    # Expected: 0.017 * 0.05 + 0.983 * 0.01 = 0.01068
    assert_in_delta(0.01068, smoother.forecast, 0.0001)
  end

  def test_add_observation_updates_smoothed_value
    initial_forecast = @smoother.forecast
    @smoother.add_observation(0.08)

    assert_operator(@smoother.forecast, :>, initial_forecast)
    assert_operator(@smoother.forecast, :<, 0.08)
  end

  def test_cap_value_drops_high_observations
    smoother = Semian::SimpleExponentialSmoother.new(initial_value: 0.01)
    initial_forecast = smoother.forecast

    20.times { smoother.add_observation(1.0) }

    assert_equal(initial_forecast, smoother.forecast)

    20.times { smoother.add_observation(0.05) }

    assert_operator(smoother.forecast, :>, initial_forecast)
  end

  def test_effect_of_30_min_incident_on_ideal_error_rate
    smoother = Semian::SimpleExponentialSmoother.new
    baseline = smoother.forecast

    180.times { smoother.add_observation(0.2) }

    assert_equal(baseline, smoother.forecast)
  end

  def test_adaptive_alpha_based_on_direction
    smoother = Semian::SimpleExponentialSmoother.new(initial_value: 0.01)

    smoother.add_observation(0.08)

    # Converging up in low confidence: alpha = 0.017
    assert_equal(0.017, smoother.alpha)
    # Expected: 0.017 * 0.08 + 0.983 * 0.01 = 0.01119
    assert_in_delta(0.01119, smoother.forecast, 0.0001)
  end

  def test_reset_returns_to_initial_state
    smoother = Semian::SimpleExponentialSmoother.new
    initial_forecast = smoother.forecast

    50.times { smoother.add_observation(0.1) }

    assert_operator(smoother.forecast, :>, initial_forecast)

    result = smoother.reset

    assert_equal(smoother, result)
    assert_equal(initial_forecast, smoother.forecast)
  end

  def test_alpha_changes_with_confidence_period
    smoother = Semian::SimpleExponentialSmoother.new(initial_value: 0.01)

    smoother.add_observation(0.08)
    low_confidence_alpha = smoother.alpha

    180.times { smoother.add_observation(0.01) }

    smoother.add_observation(0.08)
    high_confidence_alpha = smoother.alpha

    assert_operator(high_confidence_alpha, :<, low_confidence_alpha)
  end

  def test_handles_edge_case_values
    smoother = Semian::SimpleExponentialSmoother.new

    initial_value = smoother.forecast
    smoother.add_observation(0.0)

    assert_operator(smoother.forecast, :<, initial_value)

    assert_raises(ArgumentError) { smoother.add_observation(-0.1) }

    smoother.reset
    1000.times { smoother.add_observation(0.05) }

    assert_in_delta(0.05, smoother.forecast, 0.0001)
  end
end
