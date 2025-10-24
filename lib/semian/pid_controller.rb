# frozen_string_literal: true

require "thread"
require_relative "p2_estimator"

module Semian
  # PID Controller for adaptive circuit breaking
  # Based on the error function:
  # P = (error_rate - ideal_error_rate) - rejection_rate
  # Note: P increases when error_rate increases
  #       P decreases when rejection_rate increases (providing feedback)
  class PIDController
    def initialize(kp:, ki:, kd:, window_size:, initial_history_duration:, initial_error_rate:)
      # PID coefficients
      @kp = kp  # Proportional gain
      @ki = ki  # Integral gain
      @kd = kd  # Derivative gain

      # State variables
      @rejection_rate = 0.0
      @integral = 0.0
      @derivative = 0.0
      @previous_p_value = 0.0

      # Store initialization parameters
      @initial_history_duration = initial_history_duration
      @initial_error_rate = initial_error_rate
      @window_size = window_size # Time window in seconds

      # P90 error rate estimation using P2 quantile estimator
      @p90_estimator = P2QuantileEstimator.new(0.9)

      # Prefill estimator with historical knowledge
      prefill_p90_estimator

      # Current window counters
      @current_window_requests = { success: 0, error: 0, rejected: 0 }

      # Last completed window metrics (used between updates)
      @last_error_rate = 0.0

      @last_p_value = 0.0
    end

    # Record a request outcome
    def record_request(outcome)
      case outcome
      when :success
        @current_window_requests[:success] += 1
      when :error
        @current_window_requests[:error] += 1
      when :rejected
        @current_window_requests[:rejected] += 1
      end
    end

    # Update the controller at the end of each time window
    def update
      # Calculate rates for the current window
      @last_error_rate = calculate_window_error_rate

      # Store error rate for historical analysis
      store_error_rate(@last_error_rate)

      # Reset window counters for next window
      @current_window_requests = { success: 0, error: 0, rejected: 0 }

      # dt is always window_size since we update once per window
      dt = @window_size

      # Calculate the current p value
      @last_p_value = calculate_p_value(@last_error_rate)

      # PID calculations
      proportional = @kp * @last_p_value
      @integral += @last_p_value * dt
      integral = @ki * @integral
      @derivative = @kd * (@last_p_value - @previous_p_value) / dt

      # Calculate the control signal (change in rejection rate)
      control_signal = proportional + integral + @derivative

      # Update rejection rate (clamped between 0 and 1)
      @rejection_rate = (@rejection_rate + control_signal).clamp(0.0, 1.0)

      # Update state for next iteration
      @previous_p_value = @last_p_value

      @rejection_rate
    end

    # Should we reject this request based on current rejection rate?
    def should_reject?
      rand < @rejection_rate
    end

    # Reset the controller state
    def reset
      @rejection_rate = 0.0
      @integral = 0.0
      @previous_p_value = 0.0
      @derivative = 0.0
      @last_p_value = 0.0
      @current_window_requests = { success: 0, error: 0, rejected: 0 }
      @last_error_rate = 0.0
      @p90_estimator.reset

      # Refill P90 estimator after reset
      prefill_p90_estimator
    end

    # Get current metrics for monitoring/debugging
    def metrics
      {
        rejection_rate: @rejection_rate,
        error_rate: @last_error_rate,
        ideal_error_rate: calculate_ideal_error_rate,
        p_value: @last_p_value,
        integral: @integral,
        derivative: @derivative,
        previous_p_value: @previous_p_value,
        current_window_requests: @current_window_requests.dup,
        p90_estimator_state: @p90_estimator.state,
      }
    end

    private

    # Calculate the current P value
    def calculate_p_value(current_error_rate)
      ideal_error_rate = calculate_ideal_error_rate

      # P = (error_rate - ideal_error_rate) - rejection_rate
      # P increases when: error_rate > ideal
      # P decreases when: rejection_rate > 0 (feedback mechanism)
      (current_error_rate - ideal_error_rate) - @rejection_rate
    end

    def calculate_window_error_rate
      total_requests = @current_window_requests[:success] + @current_window_requests[:error]
      return 0.0 if total_requests == 0

      @current_window_requests[:error].to_f / total_requests
    end

    def store_error_rate(error_rate)
      @p90_estimator.add_observation(error_rate)
    end

    def calculate_ideal_error_rate
      return 0.01 if @p90_estimator.state[:observations] == 0 # Default to 1% if no history

      # Get P90 estimate from P2 estimator
      p90_value = @p90_estimator.estimate

      # Cap at 10% to prevent bootstrapping issues
      [p90_value, 0.1].min
    end

    # Prefill the P2 estimator with observations using initial_error_rate
    def prefill_p90_estimator
      initial_history_size = Integer(@initial_history_duration / @window_size)
      initial_history_size.times do
        @p90_estimator.add_observation(@initial_error_rate)
      end
    end
  end

  # Thread-safe version of PIDController
  class ThreadSafePIDController < PIDController
    def initialize(**kwargs)
      super(**kwargs)
      @lock = Mutex.new
    end

    def record_request(outcome)
      @lock.synchronize { super }
    end

    def update
      @lock.synchronize { super }
    end

    def should_reject?
      @lock.synchronize { super }
    end

    def reset
      @lock.synchronize { super }
    end

    # NOTE: metrics, calculate_error_rate are not overridden
    # to avoid deadlock. calculate_error_rate is private method
    # only called internally from update (synchronized) and metrics (not synchronized).
  end
end
