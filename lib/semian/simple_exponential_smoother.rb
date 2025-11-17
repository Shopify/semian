# frozen_string_literal: true

module Semian
  # SimpleExponentialSmoother implements Simple Exponential Smoothing (SES) for forecasting
  # a stable baseline error rate in adaptive circuit breakers.
  #
  # SES focuses on the level component only (no trend or seasonality), using the formula:
  #   smoothed = alpha * value + (1 - alpha) * previous_smoothed
  #
  # Key characteristics:
  # - Low alpha provides low recency bias, making it resilient to short incidents
  # - Gradually adapts to sustained changes in error rate
  # - Drops extreme values to prevent outliers from distorting the forecast
  #
  class SimpleExponentialSmoother
    DEFAULT_ALPHA = 0.001
    DEFAULT_CAP_VALUE = 0.1
    DEFAULT_INITIAL_VALUE = 0.01

    attr_reader :alpha, :initial_alpha, :cap_value, :initial_value, :smoothed_value

    def initialize(initial_alpha: DEFAULT_ALPHA, cap_value: DEFAULT_CAP_VALUE,
      initial_value: DEFAULT_INITIAL_VALUE)
      validate_alpha!(initial_alpha)

      @initial_alpha = initial_alpha
      @alpha = initial_alpha
      @cap_value = cap_value
      @initial_value = initial_value
      @smoothed_value = initial_value
      @observation_count = 0
      @consecutive_deviations = 0
      @last_deviation_direction = nil
    end

    def add_observation(value)
      raise ArgumentError, "value must be non-negative, got: #{value}" if value < 0

      @observation_count += 1

      if @observation_count == 90
        @alpha *= 0.5
      elsif @observation_count == 180
        @alpha *= 0.5
      end

      return @smoothed_value if value > cap_value

      # Ignore observations significantly above baseline after burn-in
      if @observation_count >= 5 # 5 Observations to establish baseline
        incident_threshold = @smoothed_value * 7.0
        return @smoothed_value if value > incident_threshold
      end

      # Track consecutive deviations for adaptive convergence
      relative_threshold = @smoothed_value * 0.10
      absolute_threshold = 0.001
      deviation_threshold = [relative_threshold, absolute_threshold].max

      current_deviation = value - @smoothed_value

      if current_deviation.abs > deviation_threshold
        deviation_direction = current_deviation > 0 ? :up : :down
        if deviation_direction == @last_deviation_direction
          @consecutive_deviations += 1
        else
          @consecutive_deviations = 1
          @last_deviation_direction = deviation_direction
        end
      else
        @consecutive_deviations = 0
        @last_deviation_direction = nil
      end

      # Boost alpha for sustained deviations, excluding potential incidents
      effective_alpha = alpha
      if @consecutive_deviations >= 2
        potential_incident_threshold = @smoothed_value * 6.0
        is_potential_incident = value > potential_incident_threshold

        unless is_potential_incident
          boost_multiplier = @last_deviation_direction == :down ? 300 : 150
          effective_alpha = [alpha * boost_multiplier, 0.45].min
        end
      end

      @smoothed_value = (effective_alpha * value) + ((1.0 - effective_alpha) * @smoothed_value)
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
        initial_alpha: @initial_alpha,
        cap_value: @cap_value,
        initial_value: @initial_value,
        observation_count: @observation_count,
      }
    end

    def reset
      @smoothed_value = initial_value
      @observation_count = 0
      @alpha = initial_alpha
      @consecutive_deviations = 0
      @last_deviation_direction = nil
      self
    end

    private

    def validate_alpha!(alpha)
      if alpha <= 0 || alpha >= 0.5
        raise ArgumentError, "alpha must be in range (0, 0.5), got: #{alpha}"
      end
    end
  end
end
