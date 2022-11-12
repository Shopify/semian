# frozen_string_literal: true

module Semian
  class ProtectedResource
    extend Forwardable

    def_delegators :@bulkhead, :destroy, :count, :semid, :tickets, :registered_workers
    def_delegators :@circuit_breaker, :reset, :mark_failed, :mark_success, :request_allowed?,
      :open?, :closed?, :half_open?

    attr_reader :bulkhead, :circuit_breaker, :name
    attr_accessor :updated_at

    def initialize(name, bulkhead, circuit_breaker)
      @name = name
      @bulkhead = bulkhead
      @circuit_breaker = circuit_breaker
      @updated_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def destroy
      @bulkhead&.destroy
      @circuit_breaker&.destroy
    end

    def acquire(timeout: nil, scope: nil, adapter: nil, resource: nil)
      acquire_circuit_breaker(scope, adapter, resource) do
        acquire_bulkhead(timeout, scope, adapter) do |_, wait_time|
          Semian.notify(:success, self, scope, adapter, wait_time)
          yield self
        end
      end
    end

    def in_use?
      circuit_breaker&.in_use? || bulkhead&.in_use?
    end

    private

    def acquire_circuit_breaker(scope, adapter, resource)
      if @circuit_breaker.nil?
        yield self
      else
        @circuit_breaker.acquire(resource) do
          yield self
        end
      end
    rescue ::Semian::OpenCircuitError
      Semian.notify(:circuit_open, self, scope, adapter)
      raise
    end

    def acquire_bulkhead(timeout, scope, adapter)
      if @bulkhead.nil?
        yield self, 0
      else
        @bulkhead.acquire(timeout: timeout) do |wait_time|
          yield self, wait_time
        end
      end
    rescue ::Semian::TimeoutError
      Semian.notify(:busy, self, scope, adapter)
      raise
    end
  end
end
