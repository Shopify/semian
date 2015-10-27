require 'forwardable'

module Semian
  class ProtectedResource
    extend Forwardable

    def_delegators :@resource, :destroy, :count, :semid, :tickets, :name
    def_delegators :@circuit_breaker, :reset, :mark_failed, :mark_success, :request_allowed?
    def_delegator :@circuit_breaker, :shared?, :circuit_breaker_shared?

    def initialize(resource, circuit_breaker)
      @resource = resource
      @circuit_breaker = circuit_breaker
    end

    def destroy
      @resource.destroy
      @circuit_breaker.destroy
    end

    def acquire(timeout: nil, scope: nil, adapter: nil)
      @circuit_breaker.acquire do
        begin
          @resource.acquire(timeout: timeout) do
            Semian.notify(:success, self, scope, adapter)
            yield self
          end
        rescue ::Semian::TimeoutError
          Semian.notify(:busy, self, scope, adapter)
          raise
        end
      end
    rescue ::Semian::OpenCircuitError
      Semian.notify(:circuit_open, self, scope, adapter)
      raise
    end
  end
end
