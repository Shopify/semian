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
      @max_history_size = history_duration # Duration in seconds to keep history

      # Request tracking for rate calculation
      @window_size = window_size # Time window in seconds for rate calculation
      @request_outcomes = [] # Array of [timestamp, :success/:error/:rejected]
      @ping_outcomes = [] # Array of [timestamp, :success/:failure]
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
      timestamp = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @request_outcomes << [timestamp, outcome]
      cleanup_old_data(timestamp)
    end

    # Record a ping outcome (ungated health check)
    def record_ping(outcome)
      timestamp = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @ping_outcomes << [timestamp, outcome]
      cleanup_old_data(timestamp)
    end

    # Update the controller with new measurements
    def update(current_error_rate = nil, ping_failure_rate = nil)
      current_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      dt = current_time - @last_update_time

      # Use calculated rates if not provided
      current_error_rate ||= calculate_error_rate
      ping_failure_rate ||= calculate_ping_failure_rate

      # Store error rate for historical analysis
      store_error_rate(current_error_rate)

      # Calculate the current error (health metric)
      error = calculate_health_metric(current_error_rate, ping_failure_rate)

      # PID calculations
      proportional = @kp * error
      @integral += error * dt
      integral = @ki * @integral
      derivative = @kd * (error - @previous_error) / dt if dt > 0
      derivative ||= 0.0

      # Calculate the control signal (change in rejection rate)
      control_signal = proportional + integral + derivative

      # Update rejection rate (clamped between 0 and 1)
      @rejection_rate = (@rejection_rate + control_signal).clamp(0.0, 1.0)

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
      @request_outcomes.clear
      @ping_outcomes.clear
      @error_rate_history.clear
    end

    # Get current metrics for monitoring/debugging
    def metrics
      {
        rejection_rate: @rejection_rate,
        error_rate: calculate_error_rate,
        ping_failure_rate: calculate_ping_failure_rate,
        ideal_error_rate: @target_error_rate || calculate_ideal_error_rate,
        health_metric: calculate_health_metric(calculate_error_rate, calculate_ping_failure_rate),
        integral: @integral,
        previous_error: @previous_error,
      }
    end

    private

    def calculate_error_rate
      current_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      cutoff_time = current_time - @window_size

      recent_requests = @request_outcomes.select { |t, _| t >= cutoff_time }
      return 0.0 if recent_requests.empty?

      errors = recent_requests.count { |_, outcome| outcome == :error }
      errors.to_f / recent_requests.size
    end

    def calculate_ping_failure_rate
      current_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      cutoff_time = current_time - @window_size

      recent_pings = @ping_outcomes.select { |t, _| t >= cutoff_time }
      return 0.0 if recent_pings.empty?

      failures = recent_pings.count { |_, outcome| outcome == :failure }
      failures.to_f / recent_pings.size
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

    def cleanup_old_data(current_time)
      cutoff_time = current_time - @window_size

      # Clean up old request outcomes
      @request_outcomes.reject! { |timestamp, _| timestamp < cutoff_time }

      # Clean up old ping outcomes
      @ping_outcomes.reject! { |timestamp, _| timestamp < cutoff_time }

      # NOTE: error_rate_history is cleaned up in store_error_rate
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
