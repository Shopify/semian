# frozen_string_literal: true

require "thread"
require_relative "simple_exponential_smoother"

module Semian
  module Simple
    # PID Controller for adaptive circuit breaking
    # Based on the error function:
    # P = (error_rate - ideal_error_rate) - (1 - (error_rate - ideal_error_rate)) * rejection_rate
    # Note: P increases when error_rate increases
    #       P decreases when rejection_rate increases (providing feedback)
    class PIDController
      attr_reader :rejection_rate

      def initialize(kp:, ki:, kd:, window_size:, sliding_interval:, implementation:, initial_error_rate:,
        dead_zone_ratio:, ideal_error_rate_estimator_cap_value:, integral_upper_cap:, integral_lower_cap:)
        @kp = kp
        @ki = ki
        @kd = kd
        @dead_zone_ratio = dead_zone_ratio
        @integral_upper_cap = integral_upper_cap
        @integral_lower_cap = integral_lower_cap

        @rejection_rate = 0.0
        @integral = 0.0
        @derivative = 0.0
        @previous_p_value = 0.0
        @last_ideal_error_rate = initial_error_rate

        @window_size = window_size
        @sliding_interval = sliding_interval
        @smoother = SimpleExponentialSmoother.new(
          cap_value: ideal_error_rate_estimator_cap_value,
          initial_value: initial_error_rate,
          observations_per_minute: 60 / sliding_interval,
        )

        @errors = implementation::SlidingWindow.new(max_size: 200 * window_size)
        @successes = implementation::SlidingWindow.new(max_size: 200 * window_size)
        @rejections = implementation::SlidingWindow.new(max_size: 200 * window_size)

        @last_error_rate = 0.0
        @last_p_value = 0.0
      end

      def record_request(outcome)
        case outcome
        when :error
          @errors.push(current_time)
        when :success
          @successes.push(current_time)
        when :rejected
          @rejections.push(current_time)
        end
      end

      def update
        # Store the last window's P value so that we can serve it up in the metrics snapshots
        @previous_p_value = @last_p_value

        @last_error_rate = calculate_error_rate

        store_error_rate(@last_error_rate)

        dt = @sliding_interval

        @last_p_value = calculate_p_value(@last_error_rate)

        proportional = @kp * @last_p_value
        @integral += @last_p_value * dt
        integral = @ki * @integral
        @derivative = @kd * (@last_p_value - @previous_p_value) / dt

        # Calculate the control signal (change in rejection rate)
        control_signal = proportional + integral + @derivative

        # Calculate what the new rejection rate would be
        new_rejection_rate = @rejection_rate + control_signal

        # Update rejection rate (clamped between 0 and 1)
        @rejection_rate = new_rejection_rate.clamp(0.0, 1.0)

        @integral = @integral.clamp(@integral_lower_cap, @integral_upper_cap)

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
        @errors.clear
        @successes.clear
        @rejections.clear
        @last_error_rate = 0.0
        @smoother.reset
        @last_ideal_error_rate = @smoother.forecast
      end

      # Get current metrics for monitoring/debugging
      def metrics(full: true)
        result = {
          rejection_rate: @rejection_rate,
          error_rate: @last_error_rate,
          ideal_error_rate: @last_ideal_error_rate,
          dead_zone_ratio: @dead_zone_ratio,
          p_value: @last_p_value,
          previous_p_value: @previous_p_value,
          integral: @integral,
          derivative: @derivative,
        }

        if full
          result[:smoother_state] = @smoother.state
          result[:current_window_requests] = {
            success: @successes.size,
            error: @errors.size,
            rejected: @rejections.size,
          }
        end

        result
      end

      private

      # Calculate the current P value with dead-zone noise suppression.
      # The dead zone prevents the controller from reacting to small, noisy
      # deviations from the ideal error rate. Only deviations exceeding
      # ideal_error_rate * dead_zone_ratio trigger a response.
      def calculate_p_value(current_error_rate)
        @last_ideal_error_rate = calculate_ideal_error_rate

        raw_delta = current_error_rate - @last_ideal_error_rate
        dead_zone = @last_ideal_error_rate * @dead_zone_ratio

        delta_error = if raw_delta <= 0
          # Below or at ideal: pass through for recovery
          raw_delta
        elsif raw_delta <= dead_zone
          # Within dead zone: suppress noise
          0.0
        else
          # Above dead zone: full signal, dead zone only silences noise
          raw_delta
        end

        delta_error - (1 - delta_error) * @rejection_rate
      end

      def calculate_error_rate
        # Clean up old observations
        current_timestamp = current_time
        cutoff_time = current_timestamp - @window_size
        @errors.reject! { |timestamp| timestamp < cutoff_time }
        @successes.reject! { |timestamp| timestamp < cutoff_time }
        @rejections.reject! { |timestamp| timestamp < cutoff_time }

        total_requests = @successes.size + @errors.size
        return 0.0 if total_requests == 0

        @errors.size.to_f / total_requests
      end

      def store_error_rate(error_rate)
        @smoother.add_observation(error_rate)
      end

      def calculate_ideal_error_rate
        @smoother.forecast
      end

      def current_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end

  module ThreadSafe
    # Thread-safe version of PIDController
    class PIDController < Simple::PIDController
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
end
