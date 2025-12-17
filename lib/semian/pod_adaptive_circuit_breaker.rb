# frozen_string_literal: true

require_relative "adaptive_circuit_breaker"
require_relative "pod_pid/client"

module Semian
  class PodAdaptiveCircuitBreaker < AdaptiveCircuitBreaker
    attr_reader :client

    def initialize(name:, exceptions: [], client: nil)
      initialize_behaviour(name: name)
      @exceptions = exceptions
      @client = client || PodPID::Client.new
      @stopped = false
      @pid_controller = ClientAdapter.new(@name, @client)
    end

    def destroy; end # No-op to satisfy AdaptiveCircuitBreaker

    private

    def start_pid_controller_update_thread; end

    class ClientAdapter
      def initialize(resource_name, client)
        @resource_name = resource_name
        @client = client
      end

      def record_request(outcome)
        @client.record_observation(@resource_name, outcome)
      end

      def should_reject?
        @client.should_reject?(@resource_name)
      end

      def rejection_rate
        @client.rejection_rate(@resource_name)
      end

      def metrics
        @client.metrics(@resource_name)
      end

      def reset; end # No-op to satisfy interface
    end
  end
end
