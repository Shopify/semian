# frozen_string_literal: true

module Semian
  # SimpleExponentialSmoother implements Simple Exponential Smoothing (SES) for forecasting
  # a stable baseline error rate in adaptive circuit breakers.
  #
  # SES focuses on the level component only (no trend or seasonality), using the formula:
  #   smoothed = alpha * value + (1 - alpha) * previous_smoothed
  #
  # Key characteristics:
  # - Drops extreme values above cap to prevent outliers from distorting the forecast
  # - Runs in two periods: low confidence (first 30 minutes) and high confidence (after 30 minutes)
  # - During the low confidence period, we converge faster towards observed value than during the high confidence period
  # - The choice of alphas follows the following criteria:
  # - During low confidence:
  #   - If we are observing 2x our current estimate, we need to converge towards it in 30 minutes
  #   - If we are observing 0.5x our current estimate, we need to converge towards it in 5 minutes
  # - During high confidence:
  #   - If we are observing 2x our current estimate, we need to converge towards it in 1 hour
  #   - If we are observing 0.5x our current estimate, we need to converge towards it in 10 minutes
  # The following code snippet can be used to calculate the alphas:
  # def find_alpha(name, start_point, multiplier, convergence_duration)
  #   target = start_point * multiplier
  #   desired_distance = 0.003
  #   alpha_ceil = 0.5
  #   alpha_floor = 0.0
  #   alpha = 0.25
  #   while true
  #      smoothed_value = start_point
  #      step_size = convergence_duration / 10
  #      converged_too_fast = false
  #      10.times do |step|
  #          step_size.times do
  #             smoothed_value = alpha * target + (1 - alpha) * smoothed_value
  #          end
  #          if step < 9 and (smoothed_value - target).abs < desired_distance
  #             converged_too_fast = true
  #          end
  #      end
  #
  #      if converged_too_fast
  #         alpha_ceil = alpha
  #         alpha = (alpha + alpha_floor) / 2
  #         next
  #      end
  #
  #      if (smoothed_value - target).abs > desired_distance
  #         alpha_floor = alpha
  #         alpha =  (alpha + alpha_ceil) / 2
  #         next
  #      end
  #
  #      break
  #   end
  #
  #   print "#{name} is #{alpha}\n"
  # end
  #
  # initial_error_rate = 0.05
  #
  # find_alpha("low confidence upward convergence alpha", initial_error_rate, 2, 1800)
  # find_alpha("low confidence downward convergence alpha", initial_error_rate, 0.5, 300)
  # find_alpha("high confidence upward convergence alpha", initial_error_rate, 2, 3600)
  # find_alpha("high confidence downward convergence alpha", initial_error_rate, 0.5, 600)
  class SimpleExponentialSmoother
    DEFAULT_CAP_VALUE = 0.1

    LOW_CONFIDENCE_ALPHA_UP = 0.0017
    LOW_CONFIDENCE_ALPHA_DOWN = 0.078
    HIGH_CONFIDENCE_ALPHA_UP = 0.0009
    HIGH_CONFIDENCE_ALPHA_DOWN = 0.039
    LOW_CONFIDENCE_THRESHOLD_MINUTES = 30

    # Validate all alpha constants at class load time
    [
      LOW_CONFIDENCE_ALPHA_UP,
      LOW_CONFIDENCE_ALPHA_DOWN,
      HIGH_CONFIDENCE_ALPHA_UP,
      HIGH_CONFIDENCE_ALPHA_DOWN,
    ].each do |alpha|
      if alpha <= 0 || alpha >= 0.5
        raise ArgumentError, "alpha constant must be in range (0, 0.5), got: #{alpha}"
      end
    end

    attr_reader :alpha, :cap_value, :initial_value, :smoothed_value, :observations_per_minute

    def initialize(cap_value: DEFAULT_CAP_VALUE, initial_value:, observations_per_minute:)
      @alpha = LOW_CONFIDENCE_ALPHA_DOWN # Start with low confidence, converging down
      @cap_value = cap_value
      @initial_value = initial_value
      @observations_per_minute = observations_per_minute
      @smoothed_value = initial_value
      @observation_count = 0
      @consecutive_deviations = 0
      @last_deviation_direction = nil
    end

    def add_observation(value)
      raise ArgumentError, "value must be non-negative, got: #{value}" if value < 0

      return @smoothed_value if value > cap_value

      @observation_count += 1

      low_confidence = @observation_count < (@observations_per_minute * LOW_CONFIDENCE_THRESHOLD_MINUTES)
      converging_up = value > @smoothed_value

      @alpha = if low_confidence
        converging_up ? LOW_CONFIDENCE_ALPHA_UP : LOW_CONFIDENCE_ALPHA_DOWN
      else
        converging_up ? HIGH_CONFIDENCE_ALPHA_UP : HIGH_CONFIDENCE_ALPHA_DOWN
      end

      @smoothed_value = (@alpha * value) + ((1.0 - @alpha) * @smoothed_value)
      @smoothed_value
    end

    def forecast
      @smoothed_value
    end

    def state
      {
        smoothed_value: @smoothed_value,
        alpha: @alpha,
        cap_value: @cap_value,
        initial_value: @initial_value,
        observations_per_minute: @observations_per_minute,
        observation_count: @observation_count,
      }
    end

    def reset
      @smoothed_value = initial_value
      @observation_count = 0
      @alpha = LOW_CONFIDENCE_ALPHA_DOWN
      self
    end
  end
end
