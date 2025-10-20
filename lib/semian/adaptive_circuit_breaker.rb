# frozen_string_literal: true

require_relative "pid_controller"

module Semian
  # Adaptive Circuit Breaker that uses PID controller for dynamic rejection
  class AdaptiveCircuitBreaker
    attr_reader :name, :pid_controller, :ping_thread, :update_thread, :last_error

    def initialize(name:, kp: 1.0, ki: 0.1, kd: 0.01,
      window_size: 10, history_duration: 3600,
      ping_interval: 1.0, thread_safe: true, enable_background_ping: true,
      seed_error_rate: 0.01)
      @name = name
      @window_size = window_size
      @ping_interval = ping_interval
      @last_ping_time = 0
      @enable_background_ping = enable_background_ping
      @resource = nil
      @stopped = false
      @last_error = nil

      # Create PID controller (thread-safe by default)
      @pid_controller = if thread_safe
        ThreadSafePIDController.new(
          name: name,
          kp: kp,
          ki: ki,
          kd: kd,
          window_size: window_size,
          history_duration: history_duration,
          seed_error_rate: seed_error_rate,
        )
      else
        PIDController.new(
          name: name,
          kp: kp,
          ki: ki,
          kd: kd,
          window_size: window_size,
          history_duration: history_duration,
          seed_error_rate: seed_error_rate,
        )
      end

      # Start background threads
      start_ping_thread if @enable_background_ping
      start_update_thread
    end

    # Main acquire method compatible with existing Semian interface
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
      rescue => error
        @pid_controller.record_request(:error)
        @last_error = error # Store the error for reporting
        raise error
      end
    end

    # Reset the adaptive circuit breaker
    def reset
      @pid_controller.reset
      @resource = nil
      @last_error = nil
    end

    # Stop the background threads (called by destroy)
    def stop
      @stopped = true
      @ping_thread&.kill
      @ping_thread = nil
      @update_thread&.kill
      @update_thread = nil
    end

    # Destroy the adaptive circuit breaker (compatible with ProtectedResource interface)
    def destroy
      stop
      @pid_controller.reset
    end

    # Destroy the adaptive circuit breaker (compatible with ProtectedResource interface)
    def destroy
      stop
      @pid_controller.reset
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
      @last_error = error
      @pid_controller.record_request(:error)
    end

    # Mark a request as successful (for compatibility with ProtectedResource)
    def mark_success
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
      # Use unprotected_ping if available, otherwise fall back to ping
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
