# frozen_string_literal: true

require_relative "process_controller"
require_relative "circuit_breaker_behaviour"

module Semian
  # Adaptive Circuit Breaker that uses Process controller for dynamic rejection
  class AdaptiveCircuitBreaker
    include CircuitBreakerBehaviour

    attr_reader :process_controller, :update_thread

    def initialize(name:, defensiveness:, window_size:, sliding_interval:, initial_error_rate:, implementation:)
      initialize_behaviour(name: name)

      @window_size = window_size
      @sliding_interval = sliding_interval
      @stopped = false

      @process_controller = implementation::ProcessController.new(
        window_size: window_size,
        sliding_interval: sliding_interval,
        defensiveness: defensiveness,
        implementation: implementation,
        initial_error_rate: initial_error_rate,
      )

      start_process_controller_update_thread
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
      @process_controller.reset
    end

    def stop
      @stopped = true
      @update_thread&.kill
      @update_thread = nil
    end

    def destroy
      stop
      @process_controller.reset
    end

    def metrics
      @process_controller.metrics
    end

    def open?
      @process_controller.rejection_rate == 1
    end

    def closed?
      @process_controller.rejection_rate == 0
    end

    # half open is not a real concept for an adaptive circuit breaker. But we need to implement it for compatibility with ProtectedResource.
    # So we return true if the rejection rate is not 0 or 1.
    def half_open?
      !open? && !closed?
    end

    def mark_failed(error)
      @last_error = error
      @process_controller.record_request(:error)
    end

    def mark_success
      @process_controller.record_request(:success)
    end

    def mark_rejected
      @process_controller.record_request(:rejected)
    end

    def request_allowed?
      !@process_controller.should_reject?
    end

    def in_use?
      true
    end

    private

    def start_process_controller_update_thread
      @update_thread = Thread.new do
        loop do
          break if @stopped

          wait_for_window

          old_rejection_rate = @process_controller.rejection_rate
          pre_update_metrics = @process_controller.metrics

          @process_controller.update
          new_rejection_rate = @process_controller.rejection_rate

          check_and_notify_state_transition(old_rejection_rate, new_rejection_rate, pre_update_metrics)
          notify_metrics_update
        end
      rescue => e
        Semian.logger&.warn("[#{@name}] Process controller update thread error: #{e.message}")
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
      # Use pre-update metrics to get the window that caused the transition
      requests = pre_update_metrics[:current_window_requests]

      str = "[#{self.class.name}] State transition from #{old_state} to #{new_state}."
      str += " success_count=#{requests[:success]}"
      str += " error_count=#{requests[:error]}"
      str += " rejected_count=#{requests[:rejected]}"
      str += " rejection_rate=#{(rejection_rate * 100).round(2)}%"
      str += " error_rate=#{(pre_update_metrics[:error_rate] * 100).round(2)}%"
      str += " ideal_error_rate=#{(pre_update_metrics[:ideal_error_rate] * 100).round(2)}%"
      str += " name=\"#{@name}\""

      Semian.logger.info(str)
    end

    def notify_metrics_update
      metrics = @process_controller.metrics

      Semian.notify(
        :adaptive_update,
        self,
        nil,
        nil,
        rejection_rate: metrics[:rejection_rate],
        error_rate: metrics[:error_rate],
        ideal_error_rate: metrics[:ideal_error_rate],
        p_value: metrics[:p_value],
      )
    end
  end
end
