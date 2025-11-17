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

  def measure_convergence_percentage(initial, current, target)
    return 100.0 if initial == target

    initial_gap = (initial - target).abs
    remaining_gap = (current - target).abs
    ((initial_gap - remaining_gap) / initial_gap * 100.0)
  end

  def set_smoothed_value(smoother, value)
    smoother.instance_variable_set(:@smoothed_value, value)
  end

  public

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
    assert_raises(ArgumentError) { Semian::SimpleExponentialSmoother.new(initial_alpha: 0.5) }
    assert_raises(ArgumentError) { Semian::SimpleExponentialSmoother.new(initial_alpha: 1.5) }

    smoother = Semian::SimpleExponentialSmoother.new(initial_alpha: 0.49)

    assert_equal(0.49, smoother.alpha)
  end

  def test_smoothing_formula
    smoother = Semian::SimpleExponentialSmoother.new(initial_value: 0.01, initial_alpha: 0.1)

    smoother.add_observation(0.01)

    assert_in_delta(0.01, smoother.forecast, 0.0001)

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

    assert_equal(forecast, @smoother.forecast)
    assert_equal(@smoother.forecast, @smoother.value)
  end

  def test_cap_value_drops_high_observations
    smoother = Semian::SimpleExponentialSmoother.new(initial_alpha: 0.2, initial_value: 0.01)
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

  def test_higher_alpha_increases_recency_bias
    smoother_low = Semian::SimpleExponentialSmoother.new(initial_alpha: 0.01, initial_value: 0.01)
    smoother_high = Semian::SimpleExponentialSmoother.new(initial_alpha: 0.3, initial_value: 0.01)

    smoother_low.add_observation(0.08)
    smoother_high.add_observation(0.08)

    assert_operator(smoother_high.forecast, :>, smoother_low.forecast)
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

  def test_alpha_decreases_after_observation_thresholds
    smoother = Semian::SimpleExponentialSmoother.new(initial_alpha: 0.4)

    89.times { smoother.add_observation(0.01) }

    assert_equal(0.4, smoother.alpha)

    smoother.add_observation(0.01)

    assert_equal(0.2, smoother.alpha)

    89.times { smoother.add_observation(0.01) }

    assert_equal(0.2, smoother.alpha)

    smoother.add_observation(0.01)

    assert_equal(0.1, smoother.alpha)

    10.times { smoother.add_observation(0.01) }

    assert_equal(0.1, smoother.alpha)
  end

  def test_handles_edge_case_values
    smoother = Semian::SimpleExponentialSmoother.new

    smoother.add_observation(0.0)

    assert_operator(smoother.forecast, :<, 0.01)

    assert_raises(ArgumentError) { smoother.add_observation(-0.1) }

    smoother.reset
    1000.times { smoother.add_observation(0.01) }

    assert_in_delta(0.01, smoother.forecast, 0.0001)
  end

  # Low Confidence Incident Tests (0min to 15min)
  def test_low_confidence_incident_above_cap_rejects_all_observations
    smoother = Semian::SimpleExponentialSmoother.new
    initial_value = smoother.forecast

    simulate_observations(smoother, 0.15, 90) # Cap is 0.1, so all observations should be rejected

    assert_in_delta(initial_value, smoother.forecast, 0.005)
  end

  def test_low_confidence_incident_below_cap_stays_stable
    smoother = Semian::SimpleExponentialSmoother.new
    initial_value = smoother.forecast

    simulate_observations(smoother, 0.08, 90) # Cap is 0.1, so all observations should be accepted

    assert_in_delta(initial_value, smoother.forecast, 0.005)
  end

  def test_low_confidence_converges_down_when_too_sensitive
    smoother = Semian::SimpleExponentialSmoother.new
    target = 0.01
    set_smoothed_value(smoother, 0.03)
    initial_value = smoother.forecast

    simulate_observations(smoother, target, 18)

    convergence = measure_convergence_percentage(initial_value, smoother.forecast, target)

    assert_operator(convergence, :>, 0)

    tolerance = target * 0.10

    assert_in_delta(target, smoother.forecast, tolerance)
  end

  def test_low_confidence_converges_up_when_not_sensitive_enough
    smoother = Semian::SimpleExponentialSmoother.new
    initial_value = smoother.forecast
    actual_rate = 0.05

    simulate_observations(smoother, actual_rate, 18)

    convergence = measure_convergence_percentage(initial_value, smoother.forecast, actual_rate)

    assert_operator(convergence, :>=, 70.0)
    assert_operator(smoother.forecast, :>, initial_value)
  end

  def test_low_confidence_stays_stable_when_perfect
    smoother = Semian::SimpleExponentialSmoother.new
    initial_value = smoother.forecast

    simulate_observations(smoother, initial_value, 90)

    assert_in_delta(initial_value, smoother.forecast, 0.005)
  end

  # High Confidence Incident Tests (15min and onwards)
  def test_high_confidence_incident_above_cap_stays_stable
    smoother = Semian::SimpleExponentialSmoother.new

    simulate_observations(smoother, 0.01, 90)
    pre_incident_value = smoother.forecast

    simulate_observations(smoother, 0.15, 90)

    assert_in_delta(pre_incident_value, smoother.forecast, 0.001)
  end

  def test_high_confidence_incident_below_cap_stays_stable
    smoother = Semian::SimpleExponentialSmoother.new

    simulate_observations(smoother, 0.01, 90)
    pre_incident_value = smoother.forecast

    simulate_observations(smoother, 0.08, 90)

    assert_in_delta(pre_incident_value, smoother.forecast, 0.001)
  end

  def test_high_confidence_converges_down_when_too_sensitive
    smoother = Semian::SimpleExponentialSmoother.new
    target = 0.01

    simulate_observations(smoother, target, 90)

    set_smoothed_value(smoother, 0.03)
    initial_value = smoother.forecast

    simulate_observations(smoother, target, 18)

    convergence = measure_convergence_percentage(initial_value, smoother.forecast, target)

    assert_operator(convergence, :>, 0)
    assert_operator(smoother.forecast, :<, initial_value)
  end

  def test_high_confidence_converges_up_when_not_sensitive_enough
    smoother = Semian::SimpleExponentialSmoother.new

    simulate_observations(smoother, 0.01, 90)
    initial_value = smoother.forecast
    actual_rate = 0.05

    simulate_observations(smoother, actual_rate, 18)

    convergence = measure_convergence_percentage(initial_value, smoother.forecast, actual_rate)

    assert_operator(convergence, :>=, 70.0)
    assert_operator(smoother.forecast, :>, initial_value)
  end

  def test_high_confidence_stays_stable_when_perfect
    smoother = Semian::SimpleExponentialSmoother.new
    target = 0.01

    simulate_observations(smoother, target, 180)

    assert_in_delta(target, smoother.forecast, 0.001)
  end
end
