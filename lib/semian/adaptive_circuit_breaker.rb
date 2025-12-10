# frozen_string_literal: true

require_relative "pid_controller"
require_relative "circuit_breaker_behaviour"

module Semian
  # Adaptive Circuit Breaker that uses PID controller for dynamic rejection
  class AdaptiveCircuitBreaker
    include CircuitBreakerBehaviour

    attr_reader :pid_controller, :update_thread

    def initialize(name:, exceptions:, kp:, ki:, kd:, window_size:, sliding_interval:, initial_error_rate:, implementation:)
      initialize_behaviour(name: name)

      @exceptions = exceptions
      @sliding_interval = sliding_interval
      @stopped = false

      @pid_controller = implementation::PIDController.new(
        kp: kp,
        ki: ki,
        kd: kd,
        window_size: window_size,
        sliding_interval: sliding_interval,
        implementation: implementation,
        initial_error_rate: initial_error_rate,
      )

      start_pid_controller_update_thread
    end

    def acquire(resource = nil, &block)
      unless request_allowed?
        mark_rejected
        raise OpenCircuitError, "Rejected by adaptive circuit breaker"
      end

      result = nil
      begin
        result = block.call
      rescue *exceptions => error
        if !error.respond_to?(:marks_semian_circuits?) || error.marks_semian_circuits?
          mark_failed(error)
        end
        raise error
      else
        mark_success
      end
      result
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

    # Compatibility with ProtectedResource - Adaptive circuit breaker does not have a half open state
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

          old_rejection_rate = @pid_controller.rejection_rate
          pre_update_metrics = @pid_controller.metrics

          @pid_controller.update
          new_rejection_rate = @pid_controller.rejection_rate

          check_and_notify_state_transition(old_rejection_rate, new_rejection_rate, pre_update_metrics)
          notify_metrics_update
        end
      rescue => e
        Semian.logger&.warn("[#{@name}] PID controller update thread error: #{e.message}")
      end
    end

    def wait_for_window
      Kernel.sleep(@sliding_interval)
    end

    def check_and_notify_state_transition(old_rate, new_rate, pre_update_metrics)
      old_state = old_rate == 0.0 ? :closed : :open
      new_state = new_rate == 0.0 ? :closed : :open

      if old_state != new_state
        notify_state_transition(new_state)
        log_state_transition(old_state, new_state, new_rate, pre_update_metrics)
      end
    end

    def notify_state_transition(new_state)
      Semian.notify(:state_change, self, nil, nil, state: new_state)
    end

    def log_state_transition(old_state, new_state, rejection_rate, pre_update_metrics)
      requests = pre_update_metrics[:current_window_requests]

      str = "[#{self.class.name}] State transition from #{old_state} to #{new_state}."
      str += " success_count=#{requests[:success]}"
      str += " error_count=#{requests[:error]}"
      str += " rejected_count=#{requests[:rejected]}"
      str += " rejection_rate=#{(rejection_rate * 100).round(2)}%"
      str += " error_rate=#{(pre_update_metrics[:error_rate] * 100).round(2)}%"
      str += " ideal_error_rate=#{(pre_update_metrics[:ideal_error_rate] * 100).round(2)}%"
      str += " integral=#{pre_update_metrics[:integral].round(4)}"
      str += " name=\"#{@name}\""

      Semian.logger.info(str)
    end

    def notify_metrics_update
      metrics = @pid_controller.metrics

      Semian.notify(
        :adaptive_update,
        self,
        nil,
        nil,
        rejection_rate: metrics[:rejection_rate],
        error_rate: metrics[:error_rate],
        ideal_error_rate: metrics[:ideal_error_rate],
        p_value: metrics[:p_value],
        integral: metrics[:integral],
        derivative: metrics[:derivative],
        previous_p_value: metrics[:previous_p_value],
      )
    end
  end
end
