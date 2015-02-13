require 'forwardable'

module Semian
  class ProtectedResource
    extend Forwardable

    def_delegators :@resource, :destroy, :count, :semid, :tickets, :name
    def_delegators :@circuit_breaker, :reset

    def initialize(resource, circuit_breaker)
      @resource = resource
      @circuit_breaker = circuit_breaker
    end

    def acquire(timeout: nil, scope: nil, &block)
      @circuit_breaker.acquire do
        begin
          @resource.acquire(timeout: timeout) do
            Semian.notify(:success, self, scope)
            yield self
          end
        rescue ::Semian::TimeoutError
          Semian.notify(:occupied, self, scope)
          raise
        end
      end
    rescue ::Semian::OpenCircuitError
      Semian.notify(:circuit_open, self, scope)
      raise
    end

    def with_fallback(fallback, &block)
      @circuit_breaker.with_fallback(fallback) { @resource.acquire(&block) }
    end
  end
end
