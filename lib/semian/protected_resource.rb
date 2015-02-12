require 'forwardable'

module Semian
  class ProtectedResource
    extend Forwardable

    def_delegators :@resource, :destroy, :count, :semid, :tickets
    def_delegators :@circuit_breaker, :reset

    def initialize(resource, circuit_breaker)
      @resource = resource
      @circuit_breaker = circuit_breaker
    end

    def acquire(*args, &block)
      @circuit_breaker.acquire do
        begin
          @resource.acquire(*args) do
            Semian.notify(:success, self)
            yield self
          end
        rescue ::Semian::TimeoutError
          Semian.notify(:occupied, self)
          raise
        end
      end
    rescue ::Semian::OpenCircuitError
      Semian.notify(:circuit_open, self)
      raise
    end

    def with_fallback(fallback, &block)
      @circuit_breaker.with_fallback(fallback) { @resource.acquire(&block) }
    end
  end
end
