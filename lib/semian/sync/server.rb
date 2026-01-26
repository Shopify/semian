# frozen_string_literal: true

# Semian::Sync::CircuitBreakerServer - Server-side circuit breaker coordination
#
# Aggregates error/success reports from all connected clients and broadcasts
# state changes back to them via async-bus RPC.
#
# Components:
#   - CircuitBreakerController: State machine logic, exposed via async-bus
#   - CircuitBreakerServer: Connection management and background tasks
#
# State Machine:
#   closed -> open: error_threshold errors within error_timeout
#   open -> half_open: after error_timeout seconds
#   half_open -> closed: success_threshold successes
#   half_open -> open: any error
#
# Example:
#   server = Semian::Sync::CircuitBreakerServer.new(
#     socket_path: "/var/run/semian/semian.sock",
#     resources: { mysql_primary: { error_threshold: 3, error_timeout: 10, success_threshold: 2 } }
#   )
#   server.start

require "async"
require "async/bus/server"
require "async/bus/controller"
require "io/endpoint/unix_endpoint"
require "fileutils"
require "console"

module Semian
  module Sync
    # Circuit breaker state machine exposed via async-bus RPC.
    # Clients call methods on this controller to report errors/successes,
    # query state, and subscribe to state change broadcasts.
    class CircuitBreakerController < Async::Bus::Controller
      def initialize
        @resources = {}
        @subscribers = {} # resource_name => [subscriber_proxies]
      end

      # Report an error. Returns new state if changed, nil otherwise.
      def report_error(resource_name, timestamp)
        resource = @resources[resource_name.to_sym]
        return nil unless resource

        prev_state = resource[:state]

        # Add error to sliding window
        resource[:errors] << timestamp
        resource[:last_error_at] = timestamp

        # Remove old errors outside the window
        cutoff = timestamp - resource[:error_timeout]
        resource[:errors].reject! { |t| t < cutoff }

        # Check state transitions
        state_change = nil
        if resource[:state] == :closed && resource[:errors].size >= resource[:error_threshold]
          resource[:state] = :open
          resource[:successes] = 0
          state_change = :open
        elsif resource[:state] == :half_open
          resource[:state] = :open
          resource[:successes] = 0
          state_change = :open
        end

        Console.info(self) do
          "Error reported for #{resource_name}: errors=#{resource[:errors].size}/#{resource[:error_threshold]}, " \
            "state=#{resource[:state]}, subscribers=#{@subscribers[resource_name.to_sym]&.size || 0}"
        end

        if state_change
          Console.info(self) { "State transition: #{resource_name} #{prev_state} -> #{state_change}" }
          notify_subscribers(resource_name.to_sym, state_change)
        end
        state_change
      end

      # Report a success. Returns new state if changed, nil otherwise.
      # Only meaningful in half_open state.
      def report_success(resource_name)
        resource = @resources[resource_name.to_sym]
        return nil unless resource

        prev_state = resource[:state]

        # Successes only count in half_open state
        if resource[:state] != :half_open
          Console.info(self) do
            "Success reported for #{resource_name}: ignored (state=#{resource[:state]}, not half_open)"
          end
          return nil
        end

        resource[:successes] += 1

        state_change = nil
        if resource[:successes] >= resource[:success_threshold]
          resource[:state] = :closed
          resource[:errors].clear
          resource[:successes] = 0
          state_change = :closed
        end

        Console.info(self) do
          "Success reported for #{resource_name}: successes=#{resource[:successes]}/#{resource[:success_threshold]}, " \
            "state=#{resource[:state]}, subscribers=#{@subscribers[resource_name.to_sym]&.size || 0}"
        end

        if state_change
          Console.info(self) { "State transition: #{resource_name} #{prev_state} -> #{state_change}" }
          notify_subscribers(resource_name.to_sym, state_change)
        end
        state_change
      end

      def get_state(resource_name)
        @resources[resource_name.to_sym]&.dig(:state)
      end

      # Returns map of resource name to state for non-closed resources.
      def get_open_states
        @resources.each_with_object({}) do |(name, resource), result|
          result[name] = resource[:state] unless resource[:state] == :closed
        end
      end

      # Register a resource dynamically. Idempotent.
      # Called by clients with sync_scope: :shared. Returns { registered: bool, state: string }.
      def register_resource(name, error_threshold:, error_timeout:, success_threshold:)
        resource_sym = name.to_sym

        # Already registered - return current state
        if @resources.key?(resource_sym)
          Console.debug(self) { "Resource #{name} already registered, returning existing state" }
          return {
            registered: false,
            state: @resources[resource_sym][:state].to_s,
          }
        end

        # Register new resource
        @resources[resource_sym] = {
          name: resource_sym,
          error_threshold: error_threshold,
          error_timeout: error_timeout,
          success_threshold: success_threshold,
          errors: [],
          successes: 0,
          state: :closed,
          last_error_at: nil,
        }
        @subscribers[resource_sym] ||= []

        Console.info(self) do
          "Registered resource: #{name} (errors: #{error_threshold}, timeout: #{error_timeout}s, successes: #{success_threshold})"
        end

        {
          registered: true,
          state: "closed",
        }
      end

      # Subscribe to state changes. Subscriber must implement on_state_change(resource, state).
      def subscribe(resource_name, subscriber)
        resource = resource_name.to_sym
        @subscribers[resource] ||= []
        @subscribers[resource] << subscriber

        Console.info(self) do
          "Client subscribed to #{resource_name}: total_subscribers=#{@subscribers[resource].size}"
        end

        # Send current state if not closed
        current_state = get_state(resource_name)
        if current_state && current_state != :closed
          Console.info(self) { "Sending current state #{current_state} to new subscriber" }
          subscriber.on_state_change(resource, current_state) rescue nil
        end

        true
      end

      def unsubscribe(resource_name, subscriber)
        resource = resource_name.to_sym
        @subscribers[resource]&.delete(subscriber)
        true
      end

      # Transition open circuits to half-open if timeout elapsed.
      def check_timeouts
        state_changes = []
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        @resources.each do |name, resource|
          next unless resource[:state] == :open
          next unless resource[:last_error_at]

          elapsed = now - resource[:last_error_at]
          if elapsed >= resource[:error_timeout]
            resource[:state] = :half_open
            state_changes << { resource: name, state: :half_open }
          end
        end

        state_changes.each do |change|
          Console.info(self) do
            "State transition: #{change[:resource]} open -> half_open (timeout elapsed), " \
              "subscribers=#{@subscribers[change[:resource]]&.size || 0}"
          end
          notify_subscribers(change[:resource], change[:state])
        end

        state_changes
      end

      def statistics
        {
          resources: @resources.size,
          open_circuits: @resources.count { |_, r| r[:state] == :open },
          total_subscribers: @subscribers.values.sum(&:size),
        }
      end

      def resources
        @resources
      end

      private

      def notify_subscribers(resource_name, new_state)
        entries = @subscribers[resource_name]&.dup || []
        dead_subscribers = []

        Console.info(self) { "Broadcasting #{new_state} to #{entries.size} subscriber(s) for #{resource_name}" }

        entries.each_with_index do |subscriber, idx|
          Console.debug(self) { "Subscriber #{idx + 1} is #{subscriber.class}" }
          # Convert symbol to string for RPC serialization
          subscriber.on_state_change(resource_name.to_s, new_state.to_s)
          Console.debug(self) { "Notified subscriber #{idx + 1}/#{entries.size}" }
        rescue IOError, Errno::EPIPE, Errno::ECONNRESET, Errno::ENOTCONN => e
          # Client disconnected - mark for removal
          Console.warn(self) { "Subscriber disconnected (#{e.class}), removing" }
          dead_subscribers << subscriber
        rescue Async::Stop, Async::TimeoutError => e
          # Task stopped or timed out - client likely gone
          Console.warn(self) { "Subscriber task stopped (#{e.class}), removing" }
          dead_subscribers << subscriber
        rescue => e
          # Log unexpected errors but DON'T remove subscriber - client might still be valid
          Console.error(self) { "Failed to notify subscriber: #{e.class} - #{e.message}" }
          # Don't add to dead_subscribers - transient errors shouldn't disconnect clients
        end

        # Remove dead subscribers
        if dead_subscribers.any?
          dead_subscribers.each do |subscriber|
            @subscribers[resource_name]&.delete(subscriber)
          end
          Console.info(self) { "Removed #{dead_subscribers.size} dead subscriber(s), remaining: #{@subscribers[resource_name]&.size || 0}" }
        end
      end
    end

    # Manages circuit breaker coordination via async-bus Unix socket.
    # Accepts client connections and binds CircuitBreakerController for RPC.
    # Runs background tasks for timeout checks and periodic stats logging.
    class CircuitBreakerServer
      attr_reader :socket_path, :controller

      def initialize(socket_path:, resources: {})
        @socket_path = socket_path
        @controller = CircuitBreakerController.new
        @running = false
        @client_count = 0

        resources.each { |name, config| register_resource(name, **config) }
      end

      def register_resource(name, error_threshold:, error_timeout:, success_threshold:, **_opts)
        @controller.register_resource(
          name,
          error_threshold: error_threshold,
          error_timeout: error_timeout,
          success_threshold: success_threshold,
        )
      end

      def resources
        @controller.resources
      end

      # Start server and block until stop is called.
      def start
        # Clean up any existing socket
        File.unlink(@socket_path) if File.exist?(@socket_path)

        endpoint = IO::Endpoint.unix(@socket_path)
        bus_server = Async::Bus::Server.new(endpoint)

        @running = true

        Console.info(self) { "Semian Sync Server listening on #{@socket_path}" }

        Async do |task|
          # Background task: check for timeout transitions (open -> half_open)
          task.async do
            while @running
              sleep(1)
              @controller.check_timeouts
            end
          end

          # Background task: periodic stats logging
          task.async do
            while @running
              sleep(10)
              stats = @controller.statistics
              Console.info(self) do
                "Stats: clients=#{@client_count}, resources=#{stats[:resources]}, " \
                  "open_circuits=#{stats[:open_circuits]}, subscribers=#{stats[:total_subscribers]}"
              end
            end
          end

          # Accept client connections
          bus_server.accept do |connection|
            @client_count += 1
            Console.info(self) { "Client connected (total: #{@client_count})" }
            connection.bind(:circuit_breaker, @controller)
          rescue => e
            Console.error(self) { "Connection error: #{e.class} - #{e.message}" }
          ensure
            @client_count -= 1
            Console.info(self) { "Client disconnected (remaining: #{@client_count})" }
          end
        end
      end

      def stop
        @running = false
      end

      def running?
        @running
      end
    end
  end
end
