# frozen_string_literal: true

module Semian
  # DualCircuitBreaker wraps both classic and adaptive circuit breakers,
  # allowing runtime switching between them via a callable that determines which to use.
  class DualCircuitBreaker
    include CircuitBreakerBehaviour

    class ChildClassicCircuitBreaker < CircuitBreaker
      attr_writer :sibling

      def mark_success
        super
        @sibling.method(:mark_success).super_method.call
      end

      def mark_failed(error)
        super
        @sibling.method(:mark_failed).super_method.call(error)
      end
    end

    class ChildAdaptiveCircuitBreaker < AdaptiveCircuitBreaker
      attr_writer :sibling

      def mark_success
        super
        @sibling.method(:mark_success).super_method.call
      end

      def mark_failed(error)
        super
        @sibling.method(:mark_failed).super_method.call(error)
      end
    end

    attr_reader :classic_circuit_breaker, :adaptive_circuit_breaker, :active_circuit_breaker

    # use_adaptive should be a callable (Proc/lambda) that returns true/false
    # to determine which circuit breaker to use. If it returns true, use adaptive.
    def initialize(name:, classic_circuit_breaker:, adaptive_circuit_breaker:)
      initialize_behaviour(name: name)

      @classic_circuit_breaker = classic_circuit_breaker
      @adaptive_circuit_breaker = adaptive_circuit_breaker

      @classic_circuit_breaker.sibling = @adaptive_circuit_breaker
      @adaptive_circuit_breaker.sibling = @classic_circuit_breaker

      @active_circuit_breaker = @classic_circuit_breaker
    end

    def self.adaptive_circuit_breaker_selector(selector) # rubocop:disable Style/ClassMethodsDefinitions
      @@adaptive_circuit_breaker_selector = selector # rubocop:disable Style/ClassVars
    end

    # Main acquire method
    # Logic from both acquire methods is implemented here so that we can fan out mark_success and mark_failed
    # to both circuit breakers.
    def acquire(resource = nil, &block)
      # NOTE: This assignment is not thread-safe, but this is acceptable for now:
      # - Each request gets its own decision based on the selector at that moment
      # - The worst case is a brief inconsistency where a thread reads a stale value,
      #    which just means it uses the previous circuit breaker type for that one request
      old_type = active_breaker_type
      @active_circuit_breaker = get_active_circuit_breaker(resource)
      if old_type != active_breaker_type
        Semian.notify(:circuit_breaker_mode_change, self, nil, nil, old_mode: old_type, new_mode: active_breaker_type)
      end

      @active_circuit_breaker.acquire(resource, &block)
    end

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

    def mark_failed(error)
      @classic_circuit_breaker&.mark_failed(error)
      @adaptive_circuit_breaker&.mark_failed(error)
    end

    def mark_success
      @classic_circuit_breaker&.mark_success
      @adaptive_circuit_breaker&.mark_success
    end

    def stop
      @adaptive_circuit_breaker&.stop
    end

    def reset
      @classic_circuit_breaker&.reset
      @adaptive_circuit_breaker&.reset
    end

    def destroy
      @classic_circuit_breaker&.destroy
      @adaptive_circuit_breaker&.destroy
    end

    def in_use?
      @classic_circuit_breaker&.in_use? || @adaptive_circuit_breaker&.in_use?
    end

    def last_error
      @active_circuit_breaker.last_error
    end

    def metrics
      {
        active: active_breaker_type,
        classic: classic_metrics,
        adaptive: adaptive_metrics,
      }
    end

    private

    def classic_metrics
      return {} unless @classic_circuit_breaker

      {
        state: @classic_circuit_breaker.state&.value,
        open: @classic_circuit_breaker.open?,
        closed: @classic_circuit_breaker.closed?,
        half_open: @classic_circuit_breaker.half_open?,
      }
    end

    def adaptive_metrics
      return {} unless @adaptive_circuit_breaker

      @adaptive_circuit_breaker.metrics.merge(
        open: @adaptive_circuit_breaker.open?,
        closed: @adaptive_circuit_breaker.closed?,
        half_open: @adaptive_circuit_breaker.half_open?,
      )
    end

    def active_breaker_type
      @active_circuit_breaker.is_a?(Semian::AdaptiveCircuitBreaker) ? :adaptive : :classic
    end

    def get_active_circuit_breaker(resource)
      if use_adaptive?(resource)
        @adaptive_circuit_breaker
      else
        @classic_circuit_breaker
      end
    end

    def use_adaptive?(resource = nil)
      return false unless defined?(@@adaptive_circuit_breaker_selector)

      @@adaptive_circuit_breaker_selector.call(resource)
    rescue => e
      Semian.logger&.warn("[#{@name}] use_adaptive check failed: #{e.message}. Defaulting to classic circuit breaker.")
      false
    end
  end
end
