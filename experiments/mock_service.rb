# frozen_string_literal: true

module Semian
  module Experiments
    # MockService simulates a service with configurable endpoints, latencies, and error rates.
    # This class handles the service behavior independently from Semian integration.
    # It's designed to be thread-safe and shared across multiple client instances.
    class MockService
      attr_reader :endpoints_count, :min_latency, :max_latency, :distribution, :endpoint_latencies, :timeout, :base_error_rate

      # Initialize the mock service
      # @param endpoints_count [Integer] Number of available endpoints
      # @param min_latency [Float] Minimum latency in seconds
      # @param max_latency [Float] Maximum latency in seconds
      # @param distribution [Hash] Statistical distribution configuration
      #   For log-normal: { type: :log_normal, mean: Float, std_dev: Float }
      # @param timeout [Float, nil] Maximum time to wait for a request (in seconds). If nil, no timeout is enforced.
      # @param error_rate [Float] Baseline error rate (0.0 to 1.0). Probability that any request will fail.
      # @param deterministic_errors [Boolean] If true, use deterministic error injection for predictable testing
      # @param max_threads [Integer] Maximum number of requests that can be processed concurrently. 0 for unlimited.
      # @param queue_timeout [Float] Maximum time to wait for a request to be processed if all threads are busy. Only used if max_threads is not 0. 0 means we drop requests immediately.
      def initialize(endpoints_count:, min_latency:, max_latency:, distribution:, timeout: nil, error_rate: 0.0, deterministic_errors: false, max_threads: 0, queue_timeout: 0)
        @endpoints_count = endpoints_count
        @min_latency = min_latency
        @max_latency = max_latency
        @distribution = validate_distribution(distribution)
        @timeout = timeout
        @base_error_rate = validate_error_rate(error_rate)
        @deterministic_errors = deterministic_errors

        @thread_semaphore = max_threads > 0 ? Concurrent::Semaphore.new(max_threads) : nil
        @queue_timeout = queue_timeout

        # Initialize service degradation state
        @latency_degradation = { amount: 0.0, target: 0.0, ramp_start: nil, ramp_duration: 0 }
        @error_rate_degradation = { rate: @base_error_rate, target: @base_error_rate, ramp_start: nil, ramp_duration: 0 }

        # Phase-synchronized tracking for precise error rates
        @current_phase_requests = 0
        @current_phase_failures = 0

        # Assign fixed latencies to each endpoint
        @endpoint_latencies = generate_endpoint_latencies

        @specific_endpoint_degradations = {}

        # Mutex for thread-safe operations on shared state
        @mutex = Mutex.new
      end

      # Simulate making a request to a specific endpoint
      # @param endpoint_index [Integer] The index of the endpoint to request (0-based)
      # @raises [TimeoutError] if the request would exceed the configured timeout
      # @raises [RequestError] if the request fails based on error rate
      def request(endpoint_index, &block)
        if @thread_semaphore.nil? || @thread_semaphore.try_acquire(1, @queue_timeout)
          begin
            validate_endpoint_index(endpoint_index)

            # Calculate latency with degradation
            base_latency = @endpoint_latencies[endpoint_index]
            latency = base_latency + current_latency_degradation(endpoint_index)

            # Check if request should fail based on current error rate
            current_rate = current_error_rate
            if should_fail?(current_rate)
              # Sleep for partial latency to simulate some processing before error
              error_latency = latency * 0.3 # Fail after 30% of expected latency
              sleep(error_latency) if error_latency > 0

              raise RequestError, "Request to endpoint #{endpoint_index} failed " \
                "(error rate: #{(current_rate * 100).round(1)}%)"
            end

            # Check if request would timeout
            if @timeout && latency > @timeout
              # Sleep for the timeout period, then raise exception
              sleep(@timeout) if @timeout > 0
              raise TimeoutError,
                "Request to endpoint #{endpoint_index} timed out after #{@timeout}s " \
                  "(would have taken #{latency.round(3)}s)"
            end

            # Simulate the request with calculated latency
            sleep(latency) if latency > 0

            if block_given?
              yield(endpoint_index, latency)
            else
              { endpoint: endpoint_index, latency: latency }
            end
          ensure
            @thread_semaphore&.release(1)
          end
        else
          raise QueueTimeoutError, "Request timed out while waiting in queue"
        end
      end

      # Add fixed latency to all requests with optional ramp-up time
      # @param amount [Float] Amount of latency to add (in seconds)
      # @param ramp_time [Float] Time to ramp up to the target latency (in seconds), 0 for immediate
      def add_latency(amount, ramp_time: 0)
        raise ArgumentError, "Latency amount must be non-negative" if amount < 0
        raise ArgumentError, "Ramp time must be non-negative" if ramp_time < 0

        @mutex.synchronize do
          @latency_degradation[:target] = amount
          @latency_degradation[:ramp_start] = Time.now
          @latency_degradation[:ramp_duration] = ramp_time

          # If no ramp time, apply immediately
          @latency_degradation[:amount] = amount if ramp_time == 0
        end
      end

      # Change the error rate with optional ramp-up time
      # @param rate [Float] New error rate (0.0 to 1.0)
      # @param ramp_time [Float] Time to ramp up to the target error rate (in seconds), 0 for immediate
      def set_error_rate(rate, ramp_time: 0)
        validate_error_rate(rate)
        raise ArgumentError, "Ramp time must be non-negative" if ramp_time < 0

        @mutex.synchronize do
          @error_rate_degradation[:target] = rate
          @error_rate_degradation[:ramp_start] = Time.now
          @error_rate_degradation[:ramp_duration] = ramp_time

          # If no ramp time, apply immediately
          @error_rate_degradation[:rate] = rate if ramp_time == 0

          # Reset deterministic request counter when error rate changes
          if @deterministic_errors
            # Reset phase tracking for new error rate (perfect synchronization)
            @current_phase_requests = 0
            @current_phase_failures = 0
          end
        end
      end

      def degrade_specific_endpoint(endpoint_index, amount, ramp_time: 0)
        @mutex.synchronize do
          @specific_endpoint_degradations[endpoint_index] = {
            amount: ramp_time == 0 ? amount : 0.0, # If no ramp time, apply immediately
            target: amount,
            ramp_start: Time.now,
            ramp_duration: ramp_time,
          }
        end
      end

      # Reset service to baseline (remove all degradation)
      def reset_degradation
        @mutex.synchronize do
          @latency_degradation = { amount: 0.0, target: 0.0, ramp_start: nil, ramp_duration: 0 }
          @error_rate_degradation = { rate: @base_error_rate, target: @base_error_rate, ramp_start: nil, ramp_duration: 0 }
          @specific_endpoint_degradations = {}
          # Reset phase tracking
          @current_phase_requests = 0
          @current_phase_failures = 0
        end
      end

      # Get current latency degradation (accounting for ramp-up)
      def current_latency_degradation(endpoint_index)
        @mutex.synchronize do
          degradation = @specific_endpoint_degradations[endpoint_index] || @latency_degradation

          return degradation[:amount] unless degradation[:ramp_start] && degradation[:ramp_duration] > 0

          elapsed = Time.now - degradation[:ramp_start]
          if elapsed >= degradation[:ramp_duration]
            # Ramp complete
            degradation[:amount] = degradation[:target]
            degradation[:ramp_start] = nil
            degradation[:target]
          else
            # Still ramping
            progress = elapsed / degradation[:ramp_duration]
            current = degradation[:amount]
            target = degradation[:target]
            current + (target - current) * progress
          end
        end
      end

      # Get current error rate (accounting for ramp-up)
      def current_error_rate
        @mutex.synchronize do
          return @error_rate_degradation[:rate] unless @error_rate_degradation[:ramp_start] && @error_rate_degradation[:ramp_duration] > 0

          elapsed = Time.now - @error_rate_degradation[:ramp_start]
          if elapsed >= @error_rate_degradation[:ramp_duration]
            # Ramp complete
            @error_rate_degradation[:rate] = @error_rate_degradation[:target]
            @error_rate_degradation[:ramp_start] = nil
            @error_rate_degradation[:target]
          else
            # Still ramping
            progress = elapsed / @error_rate_degradation[:ramp_duration]
            current = @error_rate_degradation[:rate]
            target = @error_rate_degradation[:target]
            current + (target - current) * progress
          end
        end
      end

      # Get the base latency for an endpoint (without degradation effects)
      def base_latency(endpoint_index)
        validate_endpoint_index(endpoint_index)
        @endpoint_latencies[endpoint_index]
      end

      private

      def validate_distribution(dist)
        unless dist.is_a?(Hash) && dist[:type]
          raise ArgumentError, "Distribution must be a Hash with :type key"
        end

        case dist[:type]
        when :log_normal
          validate_log_normal_distribution(dist)
        else
          raise ArgumentError, "Unsupported distribution type: #{dist[:type]}. Only :log_normal is currently supported."
        end

        dist
      end

      def validate_error_rate(rate)
        unless rate.is_a?(Numeric) && rate >= 0.0 && rate <= 1.0
          raise ArgumentError, "Error rate must be a number between 0.0 and 1.0, got #{rate}"
        end

        rate
      end

      def validate_log_normal_distribution(dist)
        unless dist[:mean] && dist[:std_dev]
          raise ArgumentError, "Log-normal distribution requires :mean and :std_dev parameters"
        end

        unless dist[:mean].is_a?(Numeric) && dist[:mean] > 0
          raise ArgumentError, "Log-normal mean must be a positive number"
        end

        unless dist[:std_dev].is_a?(Numeric) && dist[:std_dev] >= 0
          raise ArgumentError, "Log-normal std_dev must be a non-negative number"
        end
      end

      def validate_endpoint_index(endpoint_index)
        unless endpoint_index.is_a?(Integer) && endpoint_index >= 0 && endpoint_index < @endpoints_count
          raise ArgumentError, "Invalid endpoint index: #{endpoint_index}. Must be between 0 and #{@endpoints_count - 1}"
        end
      end

      def generate_endpoint_latencies
        Array.new(@endpoints_count) do
          latency = sample_from_distribution
          # Clamp to min/max bounds
          latency.clamp(@min_latency, @max_latency)
        end
      end

      def should_fail?(error_rate)
        return false if error_rate <= 0

        @mutex.synchronize do
          if @deterministic_errors
            return true if error_rate >= 1.0 # Always fail if 100% error rate

            # Phase-synchronized deterministic failure optimized for closest target
            @current_phase_requests += 1

            # Calculate what error rate would be if we fail vs don't fail
            error_rate_if_fail = (@current_phase_failures + 1).to_f / @current_phase_requests
            error_rate_if_pass = @current_phase_failures.to_f / @current_phase_requests

            # Calculate distance from target for each option
            distance_if_fail = (error_rate_if_fail - error_rate).abs
            distance_if_pass = (error_rate_if_pass - error_rate).abs

            # Choose the option that gets us closer to the target
            should_fail_now = distance_if_fail < distance_if_pass

            if should_fail_now
              @current_phase_failures += 1
            end

            should_fail_now
          else
            # Use random error injection
            rand < error_rate
          end
        end
      end

      def sample_from_distribution
        case @distribution[:type]
        when :log_normal
          sample_log_normal(@distribution[:mean], @distribution[:std_dev])
        else
          # Fallback to mean value
          @distribution[:mean] || (@min_latency + @max_latency) / 2.0
        end
      end

      def sample_log_normal(mean, std_dev)
        # Convert mean and std_dev of the log-normal to the underlying normal distribution
        # Using method of moments conversion
        variance = std_dev**2
        mean_squared = mean**2

        # Calculate parameters for underlying normal distribution
        mu = Math.log(mean_squared / Math.sqrt(variance + mean_squared))
        sigma = Math.sqrt(Math.log(1 + variance / mean_squared))

        # Generate log-normal sample using Box-Muller transform
        u1 = rand
        u2 = rand
        z0 = Math.sqrt(-2.0 * Math.log(u1)) * Math.cos(2.0 * Math::PI * u2)

        # Transform to log-normal
        Math.exp(mu + sigma * z0)
      end

      # Error classes for the mock service
      class TimeoutError < StandardError
        def marks_semian_circuits?
          true  # This error should trigger circuit breaker
        end
      end

      class RequestError < StandardError
        def marks_semian_circuits?
          true  # This error should trigger circuit breaker
        end
      end

      class QueueTimeoutError < StandardError
        def marks_semian_circuits?
          true  # This error should trigger circuit breaker
        end
      end
    end
  end
end
