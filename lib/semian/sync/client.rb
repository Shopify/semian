# frozen_string_literal: true

# Semian::Sync::Client - Client-side coordination for shared circuit breakers
#
# Manages communication with the CircuitBreakerServer via async-bus RPC.
# Clients report errors/successes and receive state change broadcasts.
#
# Components:
#   - SubscriberController: Receives state change callbacks from the server
#   - SemianBusClient: Persistent connection with auto-reconnect
#   - Client: Module managing connection, caching, and report queuing
#
# Example:
#   Semian::Sync::Client.configure("/var/run/semian/semian.sock")
#   Semian::Sync::Client.report_error_async(:mysql_primary, Time.now.to_f)
#   Semian::Sync::Client.subscribe_to_updates(:mysql_primary) { |state| ... }

require "async"
require "async/bus/client"
require "async/bus/controller"
require "async/condition"
require "io/endpoint/unix_endpoint"

module Semian
  module Sync
    # Receives state change callbacks from the server via RPC.
    # Passed by reference to server's subscribe method for bidirectional communication.
    class SubscriberController < Async::Bus::Controller
      def initialize(client)
        @client = client
      end

      # Called by server when a resource's state changes (via RPC callback).
      # Must return a serializable value for RPC response.
      def on_state_change(resource_name, new_state)
        @client.handle_state_change(resource_name, new_state)
        true
      end
    end

    # Persistent async-bus connection with auto-reconnect.
    # Owns the full connection lifecycle including the run task.
    #
    # Usage:
    #   bus_client = SemianBusClient.new(endpoint, client_manager)
    #   bus_client.start_connection(timeout: 5.0)
    #   bus_client.circuit_breaker.report_error(...)
    #   bus_client.disconnect
    #
    class SemianBusClient < Async::Bus::Client
      attr_reader :circuit_breaker, :connection, :subscriber_proxy

      def initialize(endpoint, client_manager)
        super(endpoint)
        @client_manager = client_manager
        @run_task = nil
        @connection = nil
        @circuit_breaker = nil
        @subscriber = nil
        @subscriber_proxy = nil
        @connection_ready = Async::Condition.new
        @connection_failed = false
      end

      def connected?
        @connection != nil && @circuit_breaker != nil
      end

      # Start the async-bus run loop and wait for connection.
      def start_connection(timeout: 5.0)
        return if @run_task

        @run_task = run
        wait_for_connection(timeout: timeout)
      end

      # Cleanly disconnect and stop the run task.
      def disconnect
        @run_task&.stop rescue nil
        @run_task = nil
        @connection&.close rescue nil
        @connection = nil
        @circuit_breaker = nil
      end

      def mark_failed!
        @connection = nil
        @circuit_breaker = nil
        @connection_failed = true
        @connection_ready.signal
      end

      # Called by async-bus on connection (initial and reconnections).
      protected def connected!(connection)
        @connection_failed = false
        @connection = connection
        @circuit_breaker = connection[:circuit_breaker]

        # Bind subscriber controller for receiving server callbacks
        @subscriber = SubscriberController.new(@client_manager)
        @subscriber_proxy = connection.bind(:subscriber, @subscriber)

        @client_manager.log_info("Connected to server")
        @client_manager.on_connected(self)
        @connection_ready.signal
      rescue => e
        @client_manager.log_error("Setup error in connected!: #{e.message}")
        @connection = nil
        @circuit_breaker = nil
        @connection_failed = true
        @connection_ready.signal
      end

      private

      # Block until connected or timeout. Returns immediately if already connected.
      def wait_for_connection(timeout: 5.0)
        return true if connected?
        return false if @connection_failed

        Async do |task|
          task.with_timeout(timeout) do
            @connection_ready.wait until connected? || @connection_failed
          end
        rescue Async::TimeoutError
          # Timeout waiting for connection
        end

        connected?
      end
    end

    # Module managing server communication for shared circuit breakers.
    #
    # Responsibilities:
    #   - Auto-reconnecting connection via async-bus
    #   - Error/success reporting via RPC
    #   - State change callbacks via subscriber controller
    #   - Local state caching for fast access
    #   - Report queuing when disconnected (up to MAX_QUEUE_SIZE)
    #
    # Designed for Async context (e.g., Falcon workers). Uses cooperative fibers,
    # no threads or mutexes needed.
    module Client
      extend self

      MAX_QUEUE_SIZE = 1000

      # Module-level state
      @socket_path = nil
      @bus_client = nil
      @state_cache = {}
      @subscriptions = {}
      @subscribed_resources = []
      @report_queue = []
      @setup_complete = false

      def enabled?
        ENV["SEMIAN_SYNC_ENABLED"] == "1" || ENV["SEMIAN_SYNC_ENABLED"] == "true"
      end

      def socket_path
        @socket_path || ENV["SEMIAN_SYNC_SOCKET"] || "/var/run/semian/semian.sock"
      end

      # Initialize client connection. Idempotent.
      def setup!
        return unless enabled?
        return if @setup_complete

        configure(socket_path)
        at_exit { disconnect rescue nil }
        @setup_complete = true
      end

      def configure(path)
        @socket_path = path
      end

      def connected?
        @bus_client&.connected? || false
      end

      def disconnect
        @bus_client&.disconnect
        @bus_client = nil
      end

      # Called by SubscriberController when server broadcasts a state change.
      def handle_state_change(resource_name, new_state)
        resource = resource_name.to_sym
        state = new_state.to_sym

        @state_cache[resource] = state

        @subscriptions[resource]&.each do |callback|
          callback.call(state)
        rescue => e
          log_error("Callback error for #{resource}: #{e.message}")
        end
      end

      # Called by SemianBusClient on connection/reconnection.
      # Flushes queued reports, re-registers subscriptions, syncs state.
      def on_connected(bus_client)
        flush_queued_reports
        resubscribe_resources
        sync_open_states
      end

      # Report an error for circuit breaker tracking. Queues if disconnected.
      def report_error_async(resource_name, timestamp)
        ensure_connection

        if connected?
          begin
            @bus_client.circuit_breaker.report_error(resource_name.to_s, timestamp)
          rescue => e
            log_error("Report error failed: #{e.message}")
            queue_report({ type: :error, resource: resource_name, timestamp: timestamp })
          end
        else
          queue_report({ type: :error, resource: resource_name, timestamp: timestamp })
        end
      end

      # Report a success. Only meaningful in half-open state. Queues if disconnected.
      def report_success_async(resource_name)
        ensure_connection

        if connected?
          begin
            @bus_client.circuit_breaker.report_success(resource_name.to_s)
          rescue => e
            log_error("Report success failed: #{e.message}")
            queue_report({ type: :success, resource: resource_name })
          end
        else
          queue_report({ type: :success, resource: resource_name })
        end
      end

      # Get current state from server. Falls back to cache when disconnected.
      def get_state(resource_name)
        ensure_connection

        if connected?
          begin
            state = @bus_client.circuit_breaker.get_state(resource_name.to_s)
            @state_cache[resource_name.to_sym] = state&.to_sym
            state&.to_sym
          rescue => e
            log_error("Get state failed: #{e.message}")
            @state_cache[resource_name.to_sym]
          end
        else
          @state_cache[resource_name.to_sym]
        end
      end

      # Register callback for state changes. Persisted across reconnections.
      def subscribe_to_updates(resource_name, &block)
        resource = resource_name.to_sym

        @subscriptions[resource] ||= []
        @subscriptions[resource] << block
        @subscribed_resources << resource unless @subscribed_resources.include?(resource)

        subscribe_on_server(resource) if connected?
      end

      # Register resource with server. Idempotent. Called for sync_scope: :shared resources.
      # Returns { registered: bool, state: string } or nil if failed.
      def register_resource(resource_name, config)
        ensure_connection
        return nil unless connected?

        begin
          result = @bus_client.circuit_breaker.register_resource(
            resource_name.to_s,
            error_threshold: config[:error_threshold],
            error_timeout: config[:error_timeout],
            success_threshold: config[:success_threshold],
          )

          if result && result[:state]
            @state_cache[resource_name.to_sym] = result[:state].to_sym
          end

          log_info("Registered resource #{resource_name}: #{result}")
          result
        rescue => e
          log_error("Register resource failed for #{resource_name}: #{e.message}")
          nil
        end
      end

      def log_info(message)
        Semian.logger&.info("[Semian::Sync::Client] #{message}")
      end

      def log_error(message)
        Semian.logger&.error("[Semian::Sync::Client] ERROR: #{message}")
      end

      def reset!
        disconnect
        @socket_path = nil
        @bus_client = nil
        @state_cache = {}
        @subscriptions = {}
        @subscribed_resources = []
        @report_queue = []
        @setup_complete = false
      end

      private

      # Lazily connect to server. Connection lifecycle managed by SemianBusClient.
      def ensure_connection
        return if connected?
        return if @socket_path.nil?

        # Clean up stale bus_client that failed to connect
        if @bus_client && !@bus_client.connected?
          @bus_client.disconnect rescue nil
          @bus_client = nil
        end

        return if @bus_client # Already attempting connection

        # Create client first so @bus_client is set when on_connected callback fires
        endpoint = IO::Endpoint.unix(@socket_path)
        @bus_client = SemianBusClient.new(endpoint, self)
        @bus_client.start_connection(timeout: 5.0)

        # Clear reference if connection failed
        @bus_client = nil unless @bus_client.connected?
      rescue Errno::ENOENT, Errno::ECONNREFUSED => e
        log_info("Server not available: #{e.message}")
        @bus_client&.mark_failed!
        @bus_client = nil
      rescue => e
        log_error("Connection error: #{e.class} - #{e.message}")
        @bus_client&.mark_failed!
        @bus_client = nil
      end

      def subscribe_on_server(resource_name)
        return unless @bus_client&.circuit_breaker && @bus_client&.subscriber_proxy

        begin
          @bus_client.circuit_breaker.subscribe(resource_name.to_s, @bus_client.subscriber_proxy)
        rescue => e
          log_error("Subscribe failed for #{resource_name}: #{e.message}")
        end
      end

      def resubscribe_resources
        @subscribed_resources.each { |r| subscribe_on_server(r) }
      end

      # Fetch non-closed states from server to sync cache after reconnection.
      def sync_open_states
        return unless @bus_client&.circuit_breaker

        begin
          open_states = @bus_client.circuit_breaker.get_open_states
          open_states.each do |resource, state|
            @state_cache[resource.to_sym] = state.to_sym
          end
        rescue => e
          log_error("Sync open states failed: #{e.message}")
        end
      end

      # Queue report for later delivery. Drops oldest when full.
      def queue_report(report)
        if @report_queue.size < MAX_QUEUE_SIZE
          @report_queue << report
        else
          @report_queue.shift
          @report_queue << report
          log_info("Report queue full, dropped oldest report")
        end
      end

      # Send queued reports after reconnecting.
      def flush_queued_reports
        return unless @bus_client&.circuit_breaker

        queued = @report_queue.dup
        @report_queue.clear

        queued.each do |report|
          case report[:type]
          when :error
            @bus_client.circuit_breaker.report_error(report[:resource].to_s, report[:timestamp])
          when :success
            @bus_client.circuit_breaker.report_success(report[:resource].to_s)
          end
        rescue => e
          log_error("Flush report failed: #{e.message}")
        end
      end
    end
  end
end
