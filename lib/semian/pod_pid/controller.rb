# frozen_string_literal: true

require "async"
require "async/bus"
require_relative "state_service"

module Semian
  module PodPID
    class Controller < Async::Bus::Controller
      def initialize(state_service)
        super()
        @state_service = state_service
        @clients = []
        @clients_mutex = Mutex.new

        @state_service.on_rejection_rate_change = ->(resource, rate) {
          broadcast_rejection_rate(resource, rate)
        }
      end

      def record_observation(resource, outcome)
        @state_service.record_observation(resource, outcome)
      end

      def rejection_rate(resource)
        @state_service.rejection_rate(resource)
      end

      def metrics(resource)
        @state_service.metrics(resource)
      end

      def register_client(client_proxy)
        @clients_mutex.synchronize { @clients << client_proxy }
      end

      def unregister_client(client_proxy)
        @clients_mutex.synchronize { @clients.delete(client_proxy) }
      end

      class << self
        def start(state_service)
          controller = new(state_service)

          Async do |task|
            server = Async::Bus::Server.new
            task.async { state_service.run_update_loop }
            server.accept do |connection|
              connection.bind(:pid_controller, controller)
            end
          end
        end
      end

      private

      def broadcast_rejection_rate(resource, rate)
        @clients_mutex.synchronize do
          @clients.each do |client|
            client.update_rejection_rate(resource, rate)
          rescue StandardError
            # Client disconnected
          end
        end
      end
    end
  end
end
