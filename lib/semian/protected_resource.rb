module Semian
  class ProtectedResource
    extend Forwardable

    def_delegators :@bulkhead, :destroy, :count, :semid, :tickets, :registered_workers, :name
    def_delegators :@circuit_breaker, :reset, :mark_failed, :mark_success, :request_allowed?,
                   :open?, :closed?, :half_open?

    attr_reader :bulkhead, :circuit_breaker

    def initialize(bulkhead, circuit_breaker)
      @bulkhead = bulkhead
      @circuit_breaker = circuit_breaker
    end

    def destroy
      @bulkhead.destroy unless @bulkhead.nil?
      @circuit_breaker.destroy unless @circuit_breaker.nil?
    end

    def acquire(timeout: nil, scope: nil, adapter: nil)
      acquire_circuit_breaker(scope, adapter) do
        acquire_bulkhead(timeout, scope, adapter) do
          yield self
        end
      end
    end

    private

    def acquire_circuit_breaker(scope, adapter)
      if @circuit_breaker.nil?
        yield self
      else
        @circuit_breaker.acquire do
          yield self
        end
      end
    rescue ::Semian::OpenCircuitError
      Semian.notify(:circuit_open, self, scope, adapter)
      raise
    end

    def acquire_bulkhead(timeout, scope, adapter)
      if @bulkhead.nil?
        yield self
      else
        @bulkhead.acquire(timeout: timeout) do
          Semian.notify(:success, self, scope, adapter)
          yield self
        end
      end
    rescue ::Semian::TimeoutError
      Semian.notify(:busy, self, scope, adapter)
      raise
    end
  end
end
