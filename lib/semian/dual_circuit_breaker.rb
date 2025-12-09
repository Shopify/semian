# frozen_string_literal: true

module Semian
  # DualCircuitBreaker wraps both legacy and adaptive circuit breakers,
  # allowing runtime switching between them via a callable that determines which to use.
  class DualCircuitBreaker
    include CircuitBreakerBehaviour

    attr_reader :legacy_circuit_breaker, :adaptive_circuit_breaker, :active_circuit_breaker

    # use_adaptive should be a callable (Proc/lambda) that returns true/false
    # to determine which circuit breaker to use. If it returns true, use adaptive.
    def initialize(name:, legacy_circuit_breaker:, adaptive_circuit_breaker:)
      initialize_behaviour(name: name)

      @legacy_circuit_breaker = legacy_circuit_breaker
      @adaptive_circuit_breaker = adaptive_circuit_breaker
      @active_circuit_breaker = @legacy_circuit_breaker
    end

    def self.adaptive_circuit_breaker_selector(selector)
      @@adaptive_circuit_breaker_selector = selector
    end

    # Main acquire method
    # Logic from both acquire methods is implemented here so that we can fan out mark_success and mark_failed
    # to both circuit breakers.
    def acquire(resource = nil, &block)
      @active_circuit_breaker = get_active_circuit_breaker(resource)

      if active_breaker_type == :legacy
        @active_circuit_breaker.transition_to_half_open if @active_circuit_breaker.transition_to_half_open?
      end

      unless @active_circuit_breaker.request_allowed?
        if active_breaker_type == :adaptive
          @active_circuit_breaker.mark_rejected
        end
        raise OpenCircuitError, "Rejected by #{active_breaker_type} circuit breaker"
      end

      if active_breaker_type == :adaptive
        handle_adaptive_acquire(&block)
      elsif active_breaker_type == :legacy
        handle_legacy_acquire(resource, &block)
      end
    end

    def handle_adaptive_acquire(&block)
      begin
        result = block.call
        mark_success
        result
      rescue => error
        mark_failed(error)
        raise error
      end
    end

    def handle_legacy_acquire(resource, &block)
      result = nil
      begin
        result = @active_circuit_breaker.maybe_with_half_open_resource_timeout(resource, &block)
      rescue *@active_circuit_breaker.exceptions => error
        if !error.respond_to?(:marks_semian_circuits?) || error.marks_semian_circuits?
          mark_failed(error)
        end
        raise error
      else
        mark_success
      end
      result
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

    # Stop circuit breakers (legacy doesn't implement this)
    def stop
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
      @legacy_circuit_breaker&.in_use? || @adaptive_circuit_breaker&.in_use?
    end

    # Get the last error from the active circuit breaker
    def last_error
      @active_circuit_breaker.last_error
    end

    private

    def active_breaker_type
      @active_circuit_breaker.is_a?(Semian::AdaptiveCircuitBreaker) ? :adaptive : :legacy
    end

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
