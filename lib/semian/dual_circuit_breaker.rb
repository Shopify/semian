# frozen_string_literal: true

module Semian
  # DualCircuitBreaker wraps both legacy and adaptive circuit breakers,
  # allowing runtime switching between them via a callable that determines which to use.
  class DualCircuitBreaker
    include CircuitBreakerBehaviour

    attr_reader :name, :legacy_circuit_breaker, :adaptive_circuit_breaker

    # use_adaptive should be a callable (Proc/lambda) that returns true/false
    # to determine which circuit breaker to use. If it returns true, use adaptive.
    def initialize(name:, legacy_circuit_breaker:, adaptive_circuit_breaker:)
      initialize_behaviour(name: name)

      @legacy_circuit_breaker = legacy_circuit_breaker
      @adaptive_circuit_breaker = adaptive_circuit_breaker
      @active_circuit_breaker = @adaptive_circuit_breaker
    end

    def self.adaptive_circuit_breaker_selector(selector)
      @@adaptive_circuit_breaker_selector = selector
    end

    # Main acquire method - implement directly to ensure both breakers are updated
    def acquire(resource = nil, &block)
      @active_circuit_breaker = get_active_circuit_breaker(resource)

      unless @active_circuit_breaker.request_allowed?
        mark_rejected
        raise OpenCircuitError, "Rejected by #{active_breaker_name} circuit breaker"
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

    # State query methods - delegate to active circuit breaker
    def open?
      @active_circuit_breaker.open?
    end

    def closed?
      @active_circuit_breaker.closed?
    end

    def half_open?
      @active_circuit_breaker.half_open?
    end

    def request_allowed?
      @active_circuit_breaker.request_allowed?
    end

    # Mark methods - record on BOTH circuit breakers for data consistency
    def mark_failed(error)
      @legacy_circuit_breaker&.mark_failed(error)
      @adaptive_circuit_breaker&.mark_failed(error)
    end

    def mark_success
      @legacy_circuit_breaker&.mark_success
      @adaptive_circuit_breaker&.mark_success
    end

    def mark_rejected
      @legacy_circuit_breaker&.mark_rejected if @legacy_circuit_breaker&.respond_to?(:mark_rejected)
      @adaptive_circuit_breaker&.mark_rejected
    end

    # Stop both circuit breakers
    def stop
      @legacy_circuit_breaker&.stop if @legacy_circuit_breaker&.respond_to?(:stop)
      @adaptive_circuit_breaker&.stop
    end

    # Reset both circuit breakers
    def reset
      @legacy_circuit_breaker&.reset
      @adaptive_circuit_breaker&.reset
    end

    # Destroy both circuit breakers
    def destroy
      @legacy_circuit_breaker&.destroy
      @adaptive_circuit_breaker&.destroy
    end

    # Check if either circuit breaker is in use
    def in_use?
      (@legacy_circuit_breaker&.in_use? || false) ||
        (@adaptive_circuit_breaker&.in_use? || false)
    end

    # Get the last error from the active circuit breaker
    def last_error
      @active_circuit_breaker.last_error
    end

    # Get metrics from both circuit breakers for comparison
    def metrics
      {
        active: @active_circuit_breaker&.respond_to?(:pid_controller) ? :adaptive : :legacy,
        legacy: legacy_metrics,
        adaptive: adaptive_metrics,
      }
    end

    private

    def get_active_circuit_breaker(resource)
      if use_adaptive?(resource)
        @adaptive_circuit_breaker
      else
        @legacy_circuit_breaker
      end
    end

    def use_adaptive?(resource = nil)
      return false unless defined?(@@adaptive_circuit_breaker_selector)

      @@adaptive_circuit_breaker_selector.call(resource)
    rescue => e
      # If the check fails, default to legacy for safety
      Semian.logger&.warn("[#{@name}] use_adaptive check failed: #{e.message}. Defaulting to legacy circuit breaker.")
      false
    end

    def active_breaker_name
      @active_circuit_breaker == @adaptive_circuit_breaker ? "adaptive" : "legacy"
    end

    def legacy_metrics
      return {} unless @legacy_circuit_breaker

      {
        state: @legacy_circuit_breaker.state&.value,
        open: @legacy_circuit_breaker.open?,
        closed: @legacy_circuit_breaker.closed?,
        half_open: @legacy_circuit_breaker.half_open?,
        last_error: @legacy_circuit_breaker.last_error&.message,
      }
    end

    def adaptive_metrics
      return {} unless @adaptive_circuit_breaker

      base_metrics = @adaptive_circuit_breaker.metrics
      base_metrics.merge(
        open: @adaptive_circuit_breaker.open?,
        closed: @adaptive_circuit_breaker.closed?,
        half_open: @adaptive_circuit_breaker.half_open?,
      )
    end
  end
end
