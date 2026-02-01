#!/usr/bin/env async-service
# frozen_string_literal: true

# Demo server for Circuit Breaker Sync using async-service
# Run: bundle exec async-service examples/circuit_breaker_sync/demo_server.rb
#
# This demo validates:
# - Server accepts multiple client connections via async-bus
# - Circuit breaker state machine (closed -> open -> half_open -> closed)
# - State change broadcasts to all subscribed clients
# - Proper lifecycle management via async-service

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))

require "async/service/managed_service"
require "async/service/managed_environment"
require "async/bus/server"
require "semian/sync/server"

# Service that runs the Semian circuit breaker sync server
class SemianSyncService < Async::Service::ManagedService
  def run(instance, evaluator)
    socket_path = evaluator.socket_path

    # Clean up any existing socket
    File.unlink(socket_path) if File.exist?(socket_path)

    # Create the circuit breaker controller with configured resources
    controller = Semian::Sync::CircuitBreakerController.new
    evaluator.resources.each do |name, config|
      controller.register_resource(
        name,
        error_threshold: config[:error_threshold],
        error_timeout: config[:error_timeout],
        success_threshold: config[:success_threshold],
      )
      Console.info(self) do
        "Registered resource: #{name} (errors: #{config[:error_threshold]}, " \
          "timeout: #{config[:error_timeout]}s, successes: #{config[:success_threshold]})"
      end
    end

    # Create async-bus server
    endpoint = IO::Endpoint.unix(socket_path)
    server = Async::Bus::Server.new(endpoint)
    client_count = 0

    Console.info(self) { "Semian Sync Server listening on #{socket_path}" }
    instance.ready!

    # Start background tasks
    Async do |task|
      # Timeout checker
      task.async do
        loop do
          sleep(1)
          controller.check_timeouts
        end
      end

      # Periodic stats logger
      task.async do
        loop do
          sleep(10)
          stats = controller.statistics
          Console.info(self) do
            "Stats: clients=#{client_count}, resources=#{stats[:resources]}, " \
              "open_circuits=#{stats[:open_circuits]}, subscribers=#{stats[:total_subscribers]}"
          end
        end
      end

      # Accept connections
      server.accept do |connection|
        client_count += 1
        Console.info(self) { "Client connected (total: #{client_count})" }
        connection.bind(:circuit_breaker, controller)

        # Note: async-bus handles connection lifecycle; this block runs for duration of connection
      rescue => e
        Console.error(self) { "Connection error: #{e.class} - #{e.message}" }
      ensure
        client_count -= 1
        Console.info(self) { "Client disconnected (remaining: #{client_count})" }
      end
    end

    server
  end

  private def format_title(evaluator, server)
    "semian-sync [#{evaluator.socket_path}]"
  end
end

# Environment configuration for the Semian service
module SemianEnvironment
  include Async::Service::ManagedEnvironment

  def socket_path
    ENV.fetch("SEMIAN_SOCKET_PATH", "/tmp/semian_demo.sock")
  end

  def resources
    {
      demo_resource: {
        error_threshold: 3,
        error_timeout: 10,
        success_threshold: 2,
      },
    }
  end

  def count
    1
  end
end

# Define the service
service "semian-sync" do
  service_class SemianSyncService
  include SemianEnvironment
end
