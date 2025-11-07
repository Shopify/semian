# frozen_string_literal: true

module Semian
  # SimpleExponentialSmoother implements Simple Exponential Smoothing (SES) for forecasting
  # a stable baseline error rate in adaptive circuit breakers.
  #
  # SES focuses on the level component only (no trend or seasonality), using the formula:
  #   smoothed = alpha * value + (1 - alpha) * previous_smoothed
  #
  # Key characteristics:
  # - Low alpha (default 0.05) provides low recency bias, making it resilient to short incidents
  # - Gradually adapts to sustained changes in error rate
  # - Prefills with historical baseline to establish initial state
  # - Clips extreme values to prevent outliers from distorting the forecast
  #
  # Example usage:
  #   smoother = SimpleExponentialSmoother.new
  #   smoother.add_observation(0.01)
  #   baseline = smoother.forecast  # Returns smoothed baseline error rate
  #
  class SimpleExponentialSmoother
    # Default smoothing factor (low recency bias - 5% weight on new observations)
    DEFAULT_ALPHA = 0.05

    # Default cap for incoming values (clips extreme outliers)
    DEFAULT_CAP_VALUE = 0.2

    # Default initial baseline value (typical low error rate)
    DEFAULT_PREFILL_VALUE = 0.01

    # Default number of prefill observations (simulates ~1 hour of history at 1 obs/min)
    DEFAULT_PREFILL_COUNT = 60

    attr_reader :alpha, :cap_value, :prefill_value, :smoothed_value

    # Initialize a new SimpleExponentialSmoother
    #
    # @param alpha [Float] Smoothing factor (0 < alpha <= 1). Lower values = lower recency bias.
    # @param cap_value [Float] Maximum value for clipping incoming observations.
    # @param prefill_value [Float] Initial baseline value for prefilling.
    # @param prefill_count [Integer] Number of prefill observations to bootstrap the smoother.
    # @raise [ArgumentError] If alpha is not in valid range (0, 1]
    def initialize(alpha: DEFAULT_ALPHA, cap_value: DEFAULT_CAP_VALUE,
      prefill_value: DEFAULT_PREFILL_VALUE, prefill_count: DEFAULT_PREFILL_COUNT)
      validate_alpha!(alpha)

      @alpha = alpha
      @cap_value = cap_value
      @prefill_value = prefill_value
      @prefill_count = prefill_count

      # Initialize smoothed value to prefill baseline
      @smoothed_value = prefill_value

      # Bootstrap with prefill observations to establish initial state
      # This simulates having historical data at the baseline rate
      prefill_count.times do
        add_observation(prefill_value)
      end
    end

    # Add a new observation and update the smoothed value
    #
    # Applies the SES formula:
    #   smoothed = alpha * capped_value + (1 - alpha) * previous_smoothed
    #
    # @param value [Float] The new observation to incorporate
    # @return [Float] The updated smoothed value
    def add_observation(value)
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

    # Reset the smoother to its initial state
    #
    # @return [SimpleExponentialSmoother] self for method chaining
    def reset
      @smoothed_value = prefill_value

      # Re-bootstrap with prefill observations
      @prefill_count.times do
        add_observation(prefill_value)
      end

      self
    end

    private

    # Validate that alpha is in the valid range (0, 1]
    #
    # @param alpha [Float] The alpha value to validate
    # @raise [ArgumentError] If alpha is not in valid range
    def validate_alpha!(alpha)
      unless alpha > 0 && alpha <= 1
        raise ArgumentError, "alpha must be in range (0, 1], got: #{alpha}"
      end
    end
  end
end
