# frozen_string_literal: true

require "thread"

module Semian
  # PID Controller for adaptive circuit breaking
  # Based on the health function:
  # P = (error_rate - ideal_error_rate) - (rejection_rate - ping_failure_rate)
  # Note: P increases when error_rate increases or ping_failure_rate increases
  #       P decreases when rejection_rate increases (providing feedback)
  class PIDController
    attr_reader :name, :rejection_rate

    def initialize(name:, kp: 1.0, ki: 0.1, kd: 0.0, target_error_rate: nil,
      window_size: 10, history_duration: 3600)
      @name = name

      # PID coefficients
      @kp = kp  # Proportional gain
      @ki = ki  # Integral gain
      @kd = kd  # Derivative gain

      # State variables
      @rejection_rate = 0.0
      @integral = 0.0
      @previous_error = 0.0
      @last_update_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      # Target error rate (if nil, will use historical p90)
      @target_error_rate = target_error_rate

      # Metrics tracking
      @error_rate_history = []
      @max_history_size = history_duration / window_size # Number of windows to keep

      # Discrete window tracking
      @window_size = window_size # Time window in seconds
      @window_start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      # Current window counters
      @current_window_requests = { success: 0, error: 0, rejected: 0 }
      @current_window_pings = { success: 0, failure: 0 }

      # Last completed window metrics (used between updates)
      @last_error_rate = 0.0
      @last_ping_failure_rate = 0.0
    end

    # Calculate the current health metric P
    def calculate_health_metric(current_error_rate, ping_failure_rate)
      ideal_error_rate = @target_error_rate || calculate_ideal_error_rate

      # P = (error_rate - ideal_error_rate) - (rejection_rate - ping_failure_rate)
      # P increases when: error_rate > ideal OR ping_failure_rate > rejection_rate
      # P decreases when: rejection_rate > ping_failure_rate (feedback mechanism)
      (current_error_rate - ideal_error_rate) - (@rejection_rate - ping_failure_rate)
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

    # Record a ping outcome (ungated health check)
    def record_ping(outcome)
      case outcome
      when :success
        @current_window_pings[:success] += 1
      when :failure
        @current_window_pings[:failure] += 1
      end
    end

    # Update the controller at the end of each time window
    def update(current_error_rate = nil, ping_failure_rate = nil)
      current_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      # Calculate rates for the current window
      @last_error_rate = calculate_window_error_rate
      @last_ping_failure_rate = calculate_window_ping_failure_rate

      # Store error rate for historical analysis
      store_error_rate(@last_error_rate)

      # Reset window counters for next window
      @current_window_requests = { success: 0, error: 0, rejected: 0 }
      @current_window_pings = { success: 0, failure: 0 }
      @window_start_time = current_time

      # Use provided rates or calculated rates
      current_error_rate ||= @last_error_rate
      ping_failure_rate ||= @last_ping_failure_rate

      # dt is always window_size since we update once per window
      dt = @window_size

      # Calculate the current error (health metric)
      error = calculate_health_metric(current_error_rate, ping_failure_rate)

      # PID calculations - with conditional integration to prevent windup
      proportional = @kp * error
      integral = @ki * @integral
      derivative = @kd * (error - @previous_error) / dt

      # Calculate the control signal (change in rejection rate)
      control_signal = proportional + integral + derivative

      # Calculate unclamped rejection rate to detect saturation
      unclamped_rejection_rate = @rejection_rate + control_signal

      # Update rejection rate (clamped between 0 and 1)
      @rejection_rate = unclamped_rejection_rate.clamp(0.0, 1.0)

      # Only update integral if output is not saturated (anti-windup)
      # This prevents integral buildup when the output is at its limits
      if unclamped_rejection_rate == @rejection_rate
        @integral += error * dt
      end

      # Update state for next iteration
      @previous_error = error
      @last_update_time = current_time

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
      @previous_error = 0.0
      @last_update_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @window_start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @current_window_requests = { success: 0, error: 0, rejected: 0 }
      @current_window_pings = { success: 0, failure: 0 }
      @last_error_rate = 0.0
      @last_ping_failure_rate = 0.0
      @error_rate_history.clear
    end

    # Get current metrics for monitoring/debugging
    def metrics
      {
        rejection_rate: @rejection_rate,
        error_rate: @last_error_rate,
        ping_failure_rate: @last_ping_failure_rate,
        ideal_error_rate: @target_error_rate || calculate_ideal_error_rate,
        health_metric: calculate_health_metric(@last_error_rate, @last_ping_failure_rate),
        integral: @integral,
        previous_error: @previous_error,
        current_window_requests: @current_window_requests.dup,
        current_window_pings: @current_window_pings.dup,
      }
    end

    private

    def calculate_window_error_rate
      total_requests = @current_window_requests[:success] + @current_window_requests[:error]
      return 0.0 if total_requests == 0

      @current_window_requests[:error].to_f / total_requests
    end

    def calculate_window_ping_failure_rate
      total_pings = @current_window_pings[:success] + @current_window_pings[:failure]
      return 0.0 if total_pings == 0

      @current_window_pings[:failure].to_f / total_pings
    end

    def store_error_rate(error_rate)
      @error_rate_history << error_rate
      # Keep only the last hour of data
      @error_rate_history.shift if @error_rate_history.size > @max_history_size
    end

    def calculate_ideal_error_rate
      return 0.01 if @error_rate_history.empty? # Default to 1% if no history

      # Calculate p90 of error rates
      sorted = @error_rate_history.sort
      index = (sorted.size * 0.9).floor - 1
      p90_value = sorted[index] || sorted.last

      # Cap at 10% to prevent bootstrapping issues
      [p90_value, 0.1].min
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

    def record_ping(outcome)
      @lock.synchronize { super }
    end

    def update(current_error_rate = nil, ping_failure_rate = nil)
      @lock.synchronize { super }
    end

    def should_reject?
      @lock.synchronize { super }
    end

    def reset
      @lock.synchronize { super }
    end

    # NOTE: metrics, calculate_error_rate, and calculate_ping_failure_rate are not overridden
    # to avoid deadlock. calculate_error_rate and calculate_ping_failure_rate are private methods
    # only called internally from update (synchronized) and metrics (not synchronized).
  end
end
