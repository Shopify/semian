# frozen_string_literal: true

require "async"
require "async/bus"
require "async/bus/client"

module Semian
  module PodPID
    class Client < Async::Bus::Client
      attr_reader :rejection_rates

      def initialize(**options)
        super(**options)
        @rejection_rates = {}
        @mutex = Mutex.new
        @state_service = nil
      end

      def should_reject?(resource)
        rate = @rejection_rates[resource.to_s] || 0.0
        rand < rate
      end

      def rejection_rate(resource)
        @rejection_rates[resource.to_s] || 0.0
      end

      def update_rejection_rate(resource, rate)
        @mutex.synchronize do
          @rejection_rates[resource.to_s] = rate
        end
      end

      def record_observation(resource, outcome)
        return false unless @state_service

        @state_service.record_observation(resource.to_s, outcome.to_s)
        true
      rescue StandardError
        false
      end

      def metrics(resource)
        return unless @state_service

        @state_service.metrics(resource.to_s)
      rescue StandardError
        nil
      end

      def disconnect
        @state_service&.unregister_client(@client_proxy)
        close
      rescue StandardError
        nil
      end

      protected

      def connected!(connection)
        @state_service = connection[:pid_controller]
        @client_proxy = connection[:client]
        connection.bind(:client, self)
        @state_service.register_client(@client_proxy)
      end
    end
  end
end
