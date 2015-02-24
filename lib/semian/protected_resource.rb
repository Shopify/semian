require 'forwardable'

module Semian
  class ProtectedResource
    extend Forwardable

    def_delegators :@resource, :destroy, :count, :semid, :tickets, :name
    def_delegators :@circuit_breaker, :reset, :mark_failed, :request_allowed?

    def initialize(resource, circuit_breaker)
      @resource = resource
      @circuit_breaker = circuit_breaker
    end

    def acquire(timeout: nil, scope: nil, adapter: nil, &block)
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
