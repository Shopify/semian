# frozen_string_literal: true

require "test_helper"
require "semian/simple_exponential_smoother"

class TestForecastSuccessCriteria < Minitest::Test
  DELTA_TOLERANCE = 0.01

  def setup
    @smoother = Semian::SimpleExponentialSmoother.new
    @observations_per_minute = @smoother.observations_per_minute
  end

  private

  def simulate_observations(smoother, error_rate, count)
    count.times { smoother.add_observation(error_rate) }
  end

  def minutes_to_observations(minutes)
    (minutes * @observations_per_minute).to_i
  end

  def establish_high_confidence(smoother, baseline_error_rate)
    observations = minutes_to_observations(30)
    simulate_observations(smoother, baseline_error_rate, observations)
  end

  public

  def test_low_confidence_during_incident_above_cap_stays_at_initial_value
    smoother = Semian::SimpleExponentialSmoother.new
    initial_value = smoother.forecast

    observations = minutes_to_observations(30)
    simulate_observations(smoother, 0.15, observations)

    assert_in_delta(
      initial_value,
      smoother.forecast,
      DELTA_TOLERANCE,
      "IER should stay at initial value during low confidence incident above cap",
    )
  end

  def test_low_confidence_ier_lower_than_actual_converges_in_30_minutes_for_2x_error_rate
    smoother = Semian::SimpleExponentialSmoother.new
    current_ier = smoother.forecast
    target_error_rate = current_ier * 2

    [5, 10].each do |minutes|
      observations = minutes_to_observations(5)
      simulate_observations(smoother, target_error_rate, observations)

      refute_in_delta(
        target_error_rate,
        smoother.forecast,
        DELTA_TOLERANCE,
        "IER should not have converged to target after #{minutes} minutes during low confidence",
      )
    end

    observations = minutes_to_observations(20)
    simulate_observations(smoother, target_error_rate, observations)

    assert_in_delta(
      target_error_rate,
      smoother.forecast,
      DELTA_TOLERANCE,
      "IER should converge to 2x observed rate in 30 minutes during low confidence",
    )
  end

  def test_low_confidence_ier_higher_than_actual_converges_in_5_minutes
    smoother = Semian::SimpleExponentialSmoother.new
    current_ier = smoother.forecast
    target_error_rate = current_ier * 0.5

    observations = minutes_to_observations(5)
    simulate_observations(smoother, target_error_rate, observations)

    assert_in_delta(
      target_error_rate,
      smoother.forecast,
      DELTA_TOLERANCE,
      "IER should converge to 0.5x observed rate in 5 minutes during low confidence",
    )
  end

  def test_low_confidence_ier_already_perfect_stays_static
    smoother = Semian::SimpleExponentialSmoother.new
    perfect_rate = smoother.forecast

    observations = minutes_to_observations(30)
    simulate_observations(smoother, perfect_rate, observations)

    assert_in_delta(
      perfect_rate,
      smoother.forecast,
      DELTA_TOLERANCE,
      "IER should stay static when already perfect during low confidence",
    )
  end

  def test_high_confidence_during_incident_above_cap_stays_stable
    smoother = Semian::SimpleExponentialSmoother.new
    baseline_error_rate = 0.05

    establish_high_confidence(smoother, baseline_error_rate)
    pre_incident_value = smoother.forecast

    observations = minutes_to_observations(30)
    simulate_observations(smoother, 0.15, observations)

    assert_in_delta(
      pre_incident_value,
      smoother.forecast,
      DELTA_TOLERANCE,
      "IER should stay stable during high confidence incident above cap",
    )
  end

  def test_high_confidence_ier_lower_than_actual_converges_in_1_hour
    smoother = Semian::SimpleExponentialSmoother.new
    baseline_error_rate = 0.05

    establish_high_confidence(smoother, baseline_error_rate)

    current_ier = smoother.forecast
    target_error_rate = current_ier * 2

    [10, 20].each do |minutes|
      observations = minutes_to_observations(10)
      simulate_observations(smoother, target_error_rate, observations)

      refute_in_delta(
        target_error_rate,
        smoother.forecast,
        DELTA_TOLERANCE,
        "IER should not have converged to target after #{minutes} minutes during high confidence",
      )
    end

    observations = minutes_to_observations(40)
    simulate_observations(smoother, target_error_rate, observations)

    assert_in_delta(
      target_error_rate,
      smoother.forecast,
      DELTA_TOLERANCE,
      "IER should converge to 2x observed rate in 1 hour during high confidence",
    )
  end

  def test_high_confidence_ier_higher_than_actual_converges_in_10_minutes
    smoother = Semian::SimpleExponentialSmoother.new
    baseline_error_rate = 0.05

    establish_high_confidence(smoother, baseline_error_rate)

    current_ier = smoother.forecast
    target_error_rate = current_ier * 0.5

    observations = minutes_to_observations(10)
    simulate_observations(smoother, target_error_rate, observations)

    assert_in_delta(
      target_error_rate,
      smoother.forecast,
      DELTA_TOLERANCE,
      "IER should converge to 0.5x observed rate in 10 minutes during high confidence",
    )
  end

  def test_high_confidence_ier_already_perfect_stays_static
    smoother = Semian::SimpleExponentialSmoother.new
    baseline_error_rate = 0.012

    establish_high_confidence(smoother, baseline_error_rate)
    established_ier = smoother.forecast

    observations = minutes_to_observations(30)
    simulate_observations(smoother, baseline_error_rate, observations)

    assert_in_delta(
      established_ier,
      smoother.forecast,
      DELTA_TOLERANCE,
      "IER should stay static when already perfect during high confidence",
    )
  end
end
