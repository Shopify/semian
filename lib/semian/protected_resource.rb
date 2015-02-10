require 'forwardable'

module Semian
  class ProtectedResource
    extend Forwardable

    def_delegators :@resource, :acquire, :destroy, :count, :semid
    def_delegators :@circuit_breaker, :reset

    def initialize(resource, circuit_breaker)
      @resource = resource
      @circuit_breaker = circuit_breaker
    end

    def with_fallback(fallback, &block)
      @circuit_breaker.with_fallback(fallback) { acquire(&block) }
    end
  end
end
