# frozen_string_literal: true

module Semian
  # SimpleExponentialSmoother implements Simple Exponential Smoothing (SES) for forecasting
  # a stable baseline error rate in adaptive circuit breakers.
  #
  # SES focuses on the level component only (no trend or seasonality), using the formula:
  #   smoothed = alpha * value + (1 - alpha) * previous_smoothed
  #
  # Key characteristics:
  # - Adaptive alpha adjusts based on confidence period and convergence direction
  # - Converges faster when error rate is decreasing (conservative)
  # - Converges slower when error rate is increasing (cautious)
  # - Drops extreme values above cap to prevent outliers from distorting the forecast
  #
  class SimpleExponentialSmoother
    DEFAULT_CAP_VALUE = 0.1
    DEFAULT_INITIAL_VALUE = 0.05
    DEFAULT_OBSERVATIONS_PER_MINUTE = 6

    LOW_CONFIDENCE_ALPHA_UP = 0.017
    LOW_CONFIDENCE_ALPHA_DOWN = 0.095
    HIGH_CONFIDENCE_ALPHA_UP = 0.0083
    HIGH_CONFIDENCE_ALPHA_DOWN = 0.049
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

    def initialize(cap_value: DEFAULT_CAP_VALUE,
      initial_value: DEFAULT_INITIAL_VALUE, observations_per_minute: DEFAULT_OBSERVATIONS_PER_MINUTE)
      @alpha = LOW_CONFIDENCE_ALPHA_DOWN # Start with low confidence, converging down
      @cap_value = cap_value
      @initial_value = initial_value
      @observations_per_minute = observations_per_minute
      @smoothed_value = initial_value
      @observation_count = 0
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

    def value
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
      @alpha = LOW_CONFIDENCE_ALPHA_DOWN # Reset to initial state
      self
    end
  end
end
