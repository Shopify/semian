# frozen_string_literal: true

require_relative "pid_controller"
require_relative "circuit_breaker_behaviour"

module Semian
  # Adaptive Circuit Breaker that uses PID controller for dynamic rejection
  class AdaptiveCircuitBreaker
    include CircuitBreakerBehaviour

    attr_reader :pid_controller, :update_thread

    def initialize(name:, kp:, ki:, kd:, window_size:, initial_history_duration:, initial_error_rate:, thread_safe:)
      initialize_behaviour(name: name)

      @window_size = window_size
      @stopped = false

      @pid_controller = if thread_safe
        ThreadSafePIDController.new(
          kp: kp,
          ki: ki,
          kd: kd,
          window_size: window_size,
          initial_history_duration: initial_history_duration,
          initial_error_rate: initial_error_rate,
        )
      else
        PIDController.new(
          kp: kp,
          ki: ki,
          kd: kd,
          window_size: window_size,
          initial_history_duration: initial_history_duration,
          initial_error_rate: initial_error_rate,
        )
      end

      start_pid_controller_update_thread
    end

    def acquire(resource = nil, &block)
      unless request_allowed?
        mark_rejected
        raise OpenCircuitError, "Rejected by adaptive circuit breaker"
      end

      begin
        result = block.call
        mark_success
        result
      rescue => error
        mark_failed(error)
        raise error
      end
    end

    def reset
      @last_error = nil
      @pid_controller.reset
    end

    def stop
      @stopped = true
      @update_thread&.kill
      @update_thread = nil
    end

    def destroy
      stop
      @pid_controller.reset
    end

    def metrics
      @pid_controller.metrics
    end

    def open?
      @pid_controller.rejection_rate == 1
    end

    def closed?
      @pid_controller.rejection_rate == 0
    end

    # half open is not a real concept for an adaptive circuit breaker. But we need to implement it for compatibility with ProtectedResource.
    # So we return true if the rejection rate is not 0 or 1.
    def half_open?
      !open? && !closed?
    end

    def mark_failed(error)
      @last_error = error
      @pid_controller.record_request(:error)
    end

    def mark_success
      @pid_controller.record_request(:success)
    end

    def mark_rejected
      @pid_controller.record_request(:rejected)
    end

    def request_allowed?
      !@pid_controller.should_reject?
    end

    def in_use?
      true
    end

    private

    def start_pid_controller_update_thread
      @update_thread = Thread.new do
        loop do
          break if @stopped

          wait_for_window

          @pid_controller.update
        end
      rescue => e
        Semian.logger&.warn("[#{@name}] PID controller update thread error: #{e.message}")
      end
    end

    def wait_for_window
      Kernel.sleep(@window_size)
    end
  end
end
