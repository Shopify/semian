# frozen_string_literal: true

require_relative "circuit_breaker"
require_relative "pid_controller"

module Semian
  # Adaptive Circuit Breaker that uses PID controller for dynamic rejection
  # Inherits from CircuitBreaker to maintain compatibility with existing Semian interface
  class AdaptiveCircuitBreaker < CircuitBreaker
    attr_reader :pid_controller, :ping_thread, :update_thread

    def initialize(name, exceptions:, kp: 1.0, ki: 0.1, kd: 0.01,
      window_size: 10, target_error_rate: nil,
      ping_interval: 1.0, thread_safe: true, enable_background_ping: true, **options)
      # Store adaptive-specific options
      @window_size = window_size
      @ping_interval = ping_interval
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
          target_error_rate: target_error_rate,
          window_size: window_size,
        )
      else
        PIDController.new(
          name: name,
          kp: kp,
          ki: ki,
          kd: kd,
          target_error_rate: target_error_rate,
          window_size: window_size,
        )
      end

      # Initialize parent with dummy values since we override the behavior
      # Use Simple implementation since we don't need thread-safe sliding windows (PID controller handles concurrency)
      impl = thread_safe ? Semian::ThreadSafe : Semian::Simple
      super(
        name,
        exceptions: exceptions,
        success_threshold: 1, # Not used in adaptive mode
        error_threshold: 1,   # Not used in adaptive mode
        error_timeout: 60,    # Not used in adaptive mode
        implementation: impl,
        **options.slice(:half_open_resource_timeout, :error_threshold_timeout, :error_threshold_timeout_enabled, :lumping_interval)
      )

      # Start background threads
      start_ping_thread if @enable_background_ping
      start_update_thread
    end

    # Override acquire to use PID controller instead of traditional circuit breaker logic
    def acquire(resource = nil, &block)
      # Store resource for background ping thread if needed
      @resource = resource if resource && @enable_background_ping

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
      rescue *@exceptions => error
        if !error.respond_to?(:marks_semian_circuits?) || error.marks_semian_circuits?
          @pid_controller.record_request(:error)
          @last_error = error
        end
        raise error
      end
    end

    # Override state methods to use PID controller metrics
    def open?
      @pid_controller.rejection_rate > 0.9
    end

    def closed?
      @pid_controller.rejection_rate < 0.1
    end

    def half_open?
      !open? && !closed?
    end

    # Override request_allowed? to use PID controller
    def request_allowed?
      !@pid_controller.should_reject?
    end

    # Override mark_failed to use PID controller
    def mark_failed(error)
      @last_error = error
      @pid_controller.record_request(:error)
    end

    # Override mark_success to use PID controller
    def mark_success
      @pid_controller.record_request(:success)
    end

    # Override reset to reset PID controller
    def reset
      @pid_controller.reset
      @resource = nil
      @last_error = nil
      super # Also reset parent state
    end

    # Override destroy to stop background threads
    def destroy
      stop
      @pid_controller.reset
      super
    end

    # Override in_use? to check if PID controller is active
    def in_use?
      @pid_controller.metrics[:window_requests].values.sum > 0 ||
        @pid_controller.metrics[:window_pings].values.sum > 0
    end

    # Get current metrics for monitoring (includes both PID and circuit breaker metrics)
    def metrics
      pid_metrics = @pid_controller.metrics
      {
        **pid_metrics,
        state: current_state_name,
        background_ping_enabled: @enable_background_ping,
        window_size: @window_size,
        ping_interval: @ping_interval,
      }
    end

    # Stop the background threads
    def stop
      @stopped = true
      @ping_thread&.kill
      @ping_thread = nil
      @update_thread&.kill
      @update_thread = nil
    end

    private

    def current_state_name
      return :open if open?
      return :closed if closed?

      :half_open
    end

    def start_ping_thread
      return unless @enable_background_ping

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
      return unless @resource

      ping_method = if @resource.respond_to?(:unprotected_ping)
        :unprotected_ping
      elsif @resource.respond_to?(:ping)
        :ping
      else
        return
      end

      # Send ungated ping (not affected by rejection)
      begin
        result = @resource.send(ping_method)
        if result
          @pid_controller.record_ping(:success)
        else
          @pid_controller.record_ping(:failure)
        end
      rescue => e
        @pid_controller.record_ping(:failure)
        Semian.logger&.debug("[#{@name}] Background ping failed: #{e.message}")
      end
    end

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
