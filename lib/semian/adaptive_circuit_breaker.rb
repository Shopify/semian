# frozen_string_literal: true

require_relative "pid_controller"

module Semian
  # Adaptive Circuit Breaker that uses PID controller for dynamic rejection
  class AdaptiveCircuitBreaker
    attr_reader :name, :pid_controller, :ping_thread

    def initialize(name:, kp: 1.0, ki: 0.1, kd: 0.0,
      window_size: 10, history_duration: 3600,
      ping_interval: 1.0, thread_safe: true, enable_background_ping: true)
      @name = name
      @ping_interval = ping_interval
      @last_ping_time = 0
      @enable_background_ping = enable_background_ping
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
          history_duration: history_duration,
        )
      else
        PIDController.new(
          name: name,
          kp: kp,
          ki: ki,
          kd: kd,
          window_size: window_size,
          history_duration: history_duration,
        )
      end

      # Start background ping thread if enabled
      start_ping_thread if @enable_background_ping
    end

    # Main acquire method compatible with existing Semian interface
    def acquire(resource = nil, &block)
      # Store resource for background ping thread if needed
      @resource = resource if resource && @enable_background_ping

      # Check if we should reject based on current rejection rate
      if @pid_controller.should_reject?
        @pid_controller.record_request(:rejected)
        # Update controller after rejection
        @pid_controller.update
        raise OpenCircuitError, "Rejected by adaptive circuit breaker (rejection_rate: #{@pid_controller.rejection_rate})"
      end

      # Try to execute the block
      begin
        result = block.call
        @pid_controller.record_request(:success)
        # Update controller after success
        @pid_controller.update
        result
      rescue => error
        @pid_controller.record_request(:error)
        # Update controller after error
        @pid_controller.update
        raise error
      end
    end

    # Reset the adaptive circuit breaker
    def reset
      @pid_controller.reset
      @resource = nil
    end

    # Stop the background ping thread
    def stop
      @stopped = true
      @ping_thread&.kill
      @ping_thread = nil
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

    private

    def start_ping_thread
      @ping_thread = Thread.new do
        loop do
          break if @stopped

          sleep(@ping_interval)

          # Send ping if we have a resource
          send_background_ping if @resource
        end
      rescue => e
        # Log error if logger is available
        Semian.logger&.warn("[#{@name}] Background ping thread error: #{e.message}")
      end
    end

    def send_background_ping
      return unless @resource&.respond_to?(:ping)

      # Send ungated ping (not affected by rejection)
      begin
        @resource.ping
        @pid_controller.record_ping(:success)
      rescue
        @pid_controller.record_ping(:failure)
      end
    end
  end
end
