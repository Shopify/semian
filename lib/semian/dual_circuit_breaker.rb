# frozen_string_literal: true

module Semian
  # DualCircuitBreaker wraps both legacy and adaptive circuit breakers,
  # allowing runtime switching between them via an experiment flag.
  class DualCircuitBreaker
    attr_reader :name, :legacy_circuit_breaker, :adaptive_circuit_breaker

    # experiment_flag_proc should be a callable (Proc/lambda) that returns true/false
    # to determine which circuit breaker to use. If it returns true, use adaptive.
    def initialize(name:, legacy_circuit_breaker:, adaptive_circuit_breaker:, experiment_flag_proc:)
      @name = name
      @legacy_circuit_breaker = legacy_circuit_breaker
      @adaptive_circuit_breaker = adaptive_circuit_breaker
      @experiment_flag_proc = experiment_flag_proc || ->() { false } # Default to legacy
    end

    # Main acquire method - delegates to the active circuit breaker
    def acquire(resource = nil, &block)
      active_circuit_breaker.acquire(resource, &block)
    end

    # State query methods - delegate to active circuit breaker
    def open?
      active_circuit_breaker.open?
    end

    def closed?
      active_circuit_breaker.closed?
    end

    def half_open?
      active_circuit_breaker.half_open?
    end

    def request_allowed?
      active_circuit_breaker.request_allowed?
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
      active_circuit_breaker.last_error
    end

    # Get metrics from both circuit breakers for comparison
    def metrics
      {
        active: use_adaptive? ? :adaptive : :legacy,
        legacy: legacy_metrics,
        adaptive: adaptive_metrics,
      }
    end

    # Get state from the active circuit breaker
    def state
      return nil unless @legacy_circuit_breaker

      @legacy_circuit_breaker.state
    end

    # Get error_timeout from legacy circuit breaker (for compatibility)
    def error_timeout
      return nil unless @legacy_circuit_breaker

      @legacy_circuit_breaker.error_timeout
    end

    # Get half_open_resource_timeout from legacy circuit breaker (for compatibility)
    def half_open_resource_timeout
      return nil unless @legacy_circuit_breaker

      @legacy_circuit_breaker.half_open_resource_timeout
    end

    # Get error_threshold_timeout_enabled from legacy circuit breaker (for compatibility)
    def error_threshold_timeout_enabled
      return nil unless @legacy_circuit_breaker

      @legacy_circuit_breaker.error_threshold_timeout_enabled
    end

    private

    def active_circuit_breaker
      if use_adaptive?
        @adaptive_circuit_breaker
      else
        @legacy_circuit_breaker
      end
    end

    def use_adaptive?
      @experiment_flag_proc.call
    rescue => e
      # If the flag check fails, default to legacy for safety
      Semian.logger&.warn("[#{@name}] Experiment flag check failed: #{e.message}. Defaulting to legacy circuit breaker.")
      false
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

