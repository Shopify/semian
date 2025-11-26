# frozen_string_literal: true

require "thread"
require_relative "simple_exponential_smoother"

module Semian
  module Simple
    # proportional controller for adaptive circuit breaking
    # Based on the error function:
    # P = (error_rate - ideal_error_rate) - (1/defensiveness) * rejection_rate
    # Note: P increases when error_rate increases
    #       P decreases when rejection_rate increases (providing feedback)
    class ProportionalController
      attr_reader :name, :rejection_rate

      def initialize(defensiveness:, window_size:, sliding_interval:, implementation:,
        initial_error_rate:,
        smoother_cap_value: SimpleExponentialSmoother::DEFAULT_CAP_VALUE)
        @rejection_rate = 0.0
        @defensiveness = defensiveness

        @window_size = window_size
        @sliding_interval = sliding_interval

        # Ideal error rate estimation using Simple Exponential Smoother
        @smoother = SimpleExponentialSmoother.new(
          cap_value: smoother_cap_value,
          initial_value: initial_error_rate,
          observations_per_minute: 60 / sliding_interval,
        )

        @errors = implementation::SlidingWindow.new(max_size: 200 * window_size)
        @successes = implementation::SlidingWindow.new(max_size: 200 * window_size)
        @rejections = implementation::SlidingWindow.new(max_size: 200 * window_size)

        @error_rate = 0.0
        @p_value = 0.0
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
        @error_rate = calculate_error_rate

        store_error_rate(@error_rate)

        @p_value = calculate_p_value

        # Calculate what the new rejection rate would be
        @rejection_rate = (@rejection_rate + @p_value).clamp(0.0, 1.0)
      end

      # Should we reject this request based on current rejection rate?
      def should_reject?
        rand < @rejection_rate
      end

      # Reset the controller state
      def reset
        @rejection_rate = 0.0
        @p_value = 0.0
        @errors.clear
        @successes.clear
        @rejections.clear
        @error_rate = 0.0
        @smoother.reset
      end

      # Get current metrics for monitoring/debugging
      def metrics
        {
          rejection_rate: @rejection_rate,
          error_rate: @error_rate,
          ideal_error_rate: calculate_ideal_error_rate,
          p_value: @p_value,
          smoother_state: @smoother.state,
          current_window_requests: {
            success: @successes.size,
            error: @errors.size,
            rejected: @rejections.size,
          },
        }
      end

      private

      # Calculate the current P value
      def calculate_p_value
        ideal_error_rate = calculate_ideal_error_rate

        # P = (error_rate - ideal_error_rate) - (1/defensiveness) * rejection_rate
        # P increases when: error_rate > ideal
        # P decreases when: rejection_rate > 0 (feedback mechanism)
        (@error_rate - ideal_error_rate) - (@rejection_rate / @defensiveness)
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
    # Thread-safe version of ProportionalController
    class ProportionalController < Simple::ProportionalController
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
