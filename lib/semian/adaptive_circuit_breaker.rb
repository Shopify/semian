# frozen_string_literal: true

require_relative "pid_controller"
require_relative "circuit_breaker"

module Semian
  # Adaptive Circuit Breaker that uses PID controller for dynamic rejection
  class AdaptiveCircuitBreaker < CircuitBreaker
    attr_reader :pid_controller, :update_thread

    def initialize(name:, kp: 1.0, ki: 0.1, kd: 0.01,
      window_size: 10, initial_history_duration: 900, initial_error_rate: 0.01,
      thread_safe: true, exceptions: [StandardError], implementation: Semian,
      error_timeout: 10, error_threshold: 3, success_threshold: 1)
      # Initialize parent CircuitBreaker with sensible defaults
      # The adaptive breaker doesn't use traditional state transitions,
      # but we call super to properly initialize the parent class
      super(
        name,
        exceptions: exceptions,
        success_threshold: success_threshold,
        error_threshold: error_threshold,
        error_timeout: error_timeout,
        implementation: implementation,
      )

      @window_size = window_size
      @resource = nil
      @stopped = false

      # Create PID controller (thread-safe by default)
      @pid_controller = if thread_safe
        ThreadSafePIDController.new(
          name: name,
          kp: kp,
          ki: ki,
          kd: kd,
          window_size: window_size,
          initial_history_duration: initial_history_duration,
          initial_error_rate: initial_error_rate,
        )
      else
        PIDController.new(
          name: name,
          kp: kp,
          ki: ki,
          kd: kd,
          window_size: window_size,
          initial_history_duration: initial_history_duration,
          initial_error_rate: initial_error_rate,
        )
      end

      # Start background threads
      start_update_thread
    end

    # Main acquire method compatible with existing Semian interface
    def acquire(resource = nil, &block)
      # Check if we should reject based on current rejection rate
      if @pid_controller.should_reject?
        @pid_controller.record_request(:rejected)
        raise OpenCircuitError, "Rejected by adaptive circuit breaker (rejection_rate: #{@pid_controller.rejection_rate})"
      end

      # Try to execute the block
      begin
        result = block.call
        @pid_controller.record_request(:success)
        result
      rescue => error
        @pid_controller.record_request(:error)
        @last_error = error # Store the error for reporting
        raise error
      end
    end

    # Reset the adaptive circuit breaker
    def reset
      super
      @pid_controller.reset
      @resource = nil
    end

    # Stop the background threads (called by destroy)
    def stop
      @stopped = true
      @update_thread&.kill
      @update_thread = nil
    end

    # Destroy the adaptive circuit breaker (compatible with ProtectedResource interface)
    def destroy
      stop
      @pid_controller.reset
      super
    end

    # Get current metrics for monitoring
    def metrics
      @pid_controller.metrics
    end

    # Check if circuit is effectively "open" (high rejection rate)
    def open?
      @pid_controller.rejection_rate > 0.9
    end

    # Check if circuit is effectively "closed" (low rejection rate)
    def closed?
      @pid_controller.rejection_rate < 0.1
    end

    # Check if circuit is partially open
    def half_open?
      !open? && !closed?
    end

    # Mark a request as failed (for compatibility with ProtectedResource)
    def mark_failed(error)
      super(error)
      @pid_controller.record_request(:error)
    end

    # Mark a request as successful (for compatibility with ProtectedResource)
    def mark_success
      super
      @pid_controller.record_request(:success)
    end

    # Check if requests are allowed (for compatibility with ProtectedResource)
    def request_allowed?
      !@pid_controller.should_reject?
    end

    # Check if the circuit breaker is in use (for compatibility with ProtectedResource)
    def in_use?
      true
    end

    private

    def start_update_thread
      @update_thread = Thread.new do
        loop do
          break if @stopped

          sleep(@window_size)

          # Update PID controller at the end of each window
          @pid_controller.update
        end
      rescue => e
        # Log error if logger is available
        Semian.logger&.warn("[#{@name}] Background update thread error: #{e.message}")
      end
    end
  end
end
