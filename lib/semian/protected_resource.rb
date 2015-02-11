require 'forwardable'

module Semian
  class ProtectedResource
    extend Forwardable

    def_delegators :@resource, :destroy, :count, :semid
    def_delegators :@circuit_breaker, :reset

    def initialize(resource, circuit_breaker)
      @resource = resource
      @circuit_breaker = circuit_breaker
    end

    def acquire(*args, &block)
      @circuit_breaker.acquire { @resource.acquire(*args, &block) }
    end

    def with_fallback(fallback, &block)
      @circuit_breaker.with_fallback(fallback) { @resource.acquire(&block) }
    end
  end
end
