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
  # - Clips extreme values to prevent outliers from distorting the forecast
  #
  # Example usage:
  #   smoother = SimpleExponentialSmoother.new
  #   smoother.add_observation(0.01)
  #   baseline = smoother.forecast  # Returns smoothed baseline error rate
  #
  class SimpleExponentialSmoother
    # Default smoothing factor (default is 1%, but as our "confidence" increases we decrease the alpha)
    DEFAULT_ALPHA = 0.001

    # Default cap for incoming values (clips extreme outliers)
    DEFAULT_CAP_VALUE = 0.1

    # Default initial baseline value (typical low error rate)
    DEFAULT_INITIAL_VALUE = 0.01

    attr_reader :alpha, :initial_alpha, :cap_value, :initial_value, :smoothed_value

    # Initialize a new SimpleExponentialSmoother
    #
    # @param alpha [Float] Smoothing factor (0 < alpha <= 1). Lower values = lower recency bias.
    # @param cap_value [Float] Maximum value for clipping incoming observations.
    # @param initial_value [Float] Initial baseline value for the smoother.
    # @raise [ArgumentError] If alpha is not in valid range (0, 1]
    def initialize(initial_alpha: DEFAULT_ALPHA, cap_value: DEFAULT_CAP_VALUE,
      initial_value: DEFAULT_INITIAL_VALUE)
      validate_alpha!(initial_alpha)

      @initial_alpha = initial_alpha
      @alpha = initial_alpha
      @cap_value = cap_value
      @initial_value = initial_value

      # Initialize smoothed value to initial baseline
      @smoothed_value = initial_value

      # Track the number of observations
      @observation_count = 0
    end

    # Add a new observation and update the smoothed value
    #
    # Applies the SES formula:
    #   smoothed = alpha * capped_value + (1 - alpha) * previous_smoothed
    #
    # @param value [Float] The new observation to incorporate
    # @return [Float] The updated smoothed value
    def add_observation(value)
      # We want to lower alpha as our number of observations (confidence) increases
      @observation_count += 1

      # On startup, we have a higher alpha to place more weight on first influx of observations
      if @observation_count >= 90 # 90 observations at 1 observation per minute is 15 minutes
        @alpha *= 0.5
      elsif @observation_count >= 180 # 180 observations at 1 observation per minute is 30 minutes
        @alpha *= 0.5
      end

      # Clip the incoming value to prevent extreme outliers from distorting the forecast
      capped_value = [value, cap_value].min

      # Apply Simple Exponential Smoothing formula
      # alpha controls the weight given to the new observation vs. the historical smoothed value
      @smoothed_value = (alpha * capped_value) + ((1.0 - alpha) * @smoothed_value)

      @smoothed_value
    end

    # Get the current forecast (smoothed baseline value)
    #
    # @return [Float] The current smoothed value, representing the forecasted baseline
    def forecast
      @smoothed_value
    end

    # Get the current smoothed value (alias for forecast)
    #
    # @return [Float] The current smoothed value
    def value
      @smoothed_value
    end

    # Get the current state for monitoring/debugging
    #
    # @return [Hash] Current state including smoothed value and configuration
    def state
      {
        smoothed_value: @smoothed_value,
        alpha: @alpha,
        initial_alpha: @initial_alpha,
        cap_value: @cap_value,
        initial_value: @initial_value,
      }
    end

    # Reset the smoother to its initial state
    #
    # @return [SimpleExponentialSmoother] self for method chaining
    def reset
      @smoothed_value = initial_value
      @observation_count = 0
      @alpha = initial_alpha
      self
    end

    private

    # Validate that alpha is in the valid range (0, 1]
    #
    # @param alpha [Float] The alpha value to validate
    # @raise [ArgumentError] If alpha is not in valid range
    def validate_alpha!(alpha)
      if alpha <= 0 || alpha > 1
        raise ArgumentError, "alpha must be in range (0, 1], got: #{alpha}"
      end
    end
  end
end
