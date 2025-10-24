# frozen_string_literal: true

module Semian
  module CircuitBreakerBehaviour
    attr_reader :name, :last_error

    # Initialize common circuit breaker attributes
    def initialize_behaviour(name:)
      @name = name.to_sym
      @last_error = nil
    end

    # Main method to execute a block with circuit breaker protection
    def acquire(resource = nil, &block)
      raise NotImplementedError, "#{self.class} must implement #acquire"
    end

    # Reset the circuit breaker to its initial state
    def reset
      raise NotImplementedError, "#{self.class} must implement #reset"
    end

    # Clean up resources
    def destroy
      raise NotImplementedError, "#{self.class} must implement #destroy"
    end

    # Check if the circuit is open (rejecting requests)
    def open?
      raise NotImplementedError, "#{self.class} must implement #open?"
    end

    # Check if the circuit is closed (allowing requests)
    def closed?
      raise NotImplementedError, "#{self.class} must implement #closed?"
    end

    # Check if the circuit is half-open (testing if service recovered)
    def half_open?
      raise NotImplementedError, "#{self.class} must implement #half_open?"
    end

    # Check if requests are currently allowed
    def request_allowed?
      raise NotImplementedError, "#{self.class} must implement #request_allowed?"
    end

    # Mark a request as failed
    def mark_failed(error)
      raise NotImplementedError, "#{self.class} must implement #mark_failed"
    end

    # Mark a request as successful
    def mark_success
      raise NotImplementedError, "#{self.class} must implement #mark_success"
    end

    # Check if the circuit breaker is actively tracking failures
    def in_use?
      raise NotImplementedError, "#{self.class} must implement #in_use?"
    end
  end
end
