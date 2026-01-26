# frozen_string_literal: true

require "rubygems"
require "bundler/setup"
require "minitest/autorun"

$VERBOSE = true
require "semian"
require "semian/sync/circuit_breaker"
require "semian/sync/server"
require "async/bus/server"
require "io/endpoint/bound_endpoint"

Semian.logger = Logger.new(nil, Logger::FATAL)

class CircuitBreakerSyncServerTest < Minitest::Test
  def setup
    @socket_path = "/tmp/semian_test_#{Process.pid}_#{rand(10000)}.sock"
    @server = Semian::Sync::CircuitBreakerServer.new(
      socket_path: @socket_path,
      resources: {
        test_resource: {
          error_threshold: 3,
          error_timeout: 5,
          success_threshold: 2,
        },
      },
    )
  end

  def teardown
    @server.stop if @server.running?
    File.delete(@socket_path) if File.exist?(@socket_path)
  end

  def test_register_resource
    assert @server.resources.key?(:test_resource)
    assert_equal :closed, @server.resources[:test_resource][:state]
  end

  def test_resource_transitions_to_open_after_error_threshold
    now = Time.now.to_f

    # Send 2 errors - should stay closed (using public RPC-accessible method)
    @server.controller.report_error(:test_resource, now)
    assert_equal :closed, @server.resources[:test_resource][:state]

    @server.controller.report_error(:test_resource, now + 1)
    assert_equal :closed, @server.resources[:test_resource][:state]

    # Send 3rd error - should open
    @server.controller.report_error(:test_resource, now + 2)
    assert_equal :open, @server.resources[:test_resource][:state]
  end

  def test_old_errors_expire
    now = Time.now.to_f

    # Send 2 errors
    @server.controller.report_error(:test_resource, now)
    @server.controller.report_error(:test_resource, now + 1)

    # Send error 6 seconds later (outside 5s error_timeout window)
    @server.controller.report_error(:test_resource, now + 6)

    # Should still be closed (only 1 recent error)
    assert_equal :closed, @server.resources[:test_resource][:state]
  end

  def test_error_in_half_open_reopens_circuit
    now = Time.now.to_f

    # Open the circuit
    3.times { |i| @server.controller.report_error(:test_resource, now + i) }
    assert_equal :open, @server.resources[:test_resource][:state]

    # Manually transition to half-open (via internal access for testing)
    @server.resources[:test_resource][:state] = :half_open

    # Error in half-open should reopen
    @server.controller.report_error(:test_resource, now + 10)
    assert_equal :open, @server.resources[:test_resource][:state]
  end

  def test_success_in_half_open_closes_circuit
    # Put circuit in half-open state (via internal access for testing)
    @server.resources[:test_resource][:state] = :half_open

    # Send successes
    @server.controller.report_success(:test_resource)
    assert_equal :half_open, @server.resources[:test_resource][:state]

    @server.controller.report_success(:test_resource)
    assert_equal :closed, @server.resources[:test_resource][:state]
  end

  def test_success_in_closed_state_is_ignored
    @server.controller.report_success(:test_resource)
    assert_equal :closed, @server.resources[:test_resource][:state]
    assert_equal 0, @server.resources[:test_resource][:successes]
  end

  # === Dynamic Resource Registration Tests ===

  def test_dynamic_register_resource_creates_new_resource
    # Create server with no initial resources
    empty_server = Semian::Sync::CircuitBreakerServer.new(
      socket_path: "/tmp/semian_empty_#{Process.pid}.sock",
      resources: {},
    )

    # Server starts empty
    assert_equal 0, empty_server.resources.size

    # Register resource dynamically via public RPC method
    result = empty_server.controller.register_resource(
      "dynamic_resource",
      error_threshold: 5,
      error_timeout: 30,
      success_threshold: 3,
    )

    # Should report as newly registered
    assert result[:registered], "Should report as newly registered"
    assert_equal "closed", result[:state]

    # Resource should now exist
    assert_equal 1, empty_server.resources.size
    assert empty_server.resources.key?(:dynamic_resource)

    # Check configuration was applied correctly
    resource = empty_server.resources[:dynamic_resource]
    assert_equal 5, resource[:error_threshold]
    assert_equal 30, resource[:error_timeout]
    assert_equal 3, resource[:success_threshold]
    assert_equal :closed, resource[:state]
  end

  def test_dynamic_register_resource_is_idempotent
    # Create server with no initial resources
    empty_server = Semian::Sync::CircuitBreakerServer.new(
      socket_path: "/tmp/semian_empty_#{Process.pid}.sock",
      resources: {},
    )

    # Register resource first time
    result1 = empty_server.controller.register_resource(
      "idempotent_resource",
      error_threshold: 3,
      error_timeout: 10,
      success_threshold: 2,
    )
    assert result1[:registered], "First registration should report as new"

    # Change state to open (simulating circuit breaker opening)
    empty_server.resources[:idempotent_resource][:state] = :open

    # Register same resource again with different config
    result2 = empty_server.controller.register_resource(
      "idempotent_resource",
      error_threshold: 10,
      error_timeout: 60,
      success_threshold: 5,
    )

    # Should NOT be marked as newly registered
    refute result2[:registered], "Second registration should not be marked as new"

    # Should return current state
    assert_equal "open", result2[:state]

    # Original config should be preserved (not overwritten)
    resource = empty_server.resources[:idempotent_resource]
    assert_equal 3, resource[:error_threshold], "Original config should be preserved"
    assert_equal 10, resource[:error_timeout], "Original config should be preserved"
  end

  def test_dynamic_resource_can_report_errors_after_registration
    # Create server with no initial resources
    empty_server = Semian::Sync::CircuitBreakerServer.new(
      socket_path: "/tmp/semian_empty_#{Process.pid}.sock",
      resources: {},
    )

    # Register resource dynamically
    empty_server.controller.register_resource(
      "error_test_resource",
      error_threshold: 2,
      error_timeout: 10,
      success_threshold: 1,
    )

    # Report errors to open the circuit
    now = Time.now.to_f
    empty_server.controller.report_error(:error_test_resource, now)
    assert_equal :closed, empty_server.resources[:error_test_resource][:state]

    empty_server.controller.report_error(:error_test_resource, now + 1)
    assert_equal :open, empty_server.resources[:error_test_resource][:state]
  end

  def test_subscribe_and_unsubscribe
    subscriber1 = Object.new
    subscriber2 = Object.new

    @server.controller.subscribe(:test_resource, subscriber1)
    @server.controller.subscribe(:test_resource, subscriber2)

    # Should have 2 subscribers
    assert_equal 2, @server.controller.statistics[:total_subscribers]

    # Unsubscribe one
    @server.controller.unsubscribe(:test_resource, subscriber1)
    assert_equal 1, @server.controller.statistics[:total_subscribers]

    # Unsubscribe the other
    @server.controller.unsubscribe(:test_resource, subscriber2)
    assert_equal 0, @server.controller.statistics[:total_subscribers]
  end
end

class CircuitBreakerSyncClientTest < Minitest::Test
  def setup
    Semian::Sync::Client.reset!
    @received_states = []
  end

  def teardown
    Semian::Sync::Client.reset!
  end

  def test_queue_reports_when_disconnected
    refute Semian::Sync::Client.connected?

    # Report should be queued, not fail
    Semian::Sync::Client.report_error_async(:test_resource, Time.now.to_f)

    queue = Semian::Sync::Client.instance_variable_get(:@report_queue)
    assert_equal 1, queue.size
    assert_equal :error, queue.first[:type]
  end

  def test_queue_overflow_drops_oldest
    # Fill queue beyond max (default 1000, but we'll test the behavior)
    max_queue = Semian::Sync::Client::MAX_QUEUE_SIZE
    (max_queue + 5).times do |i|
      Semian::Sync::Client.report_error_async("resource_#{i}", Time.now.to_f)
    end

    queue = Semian::Sync::Client.instance_variable_get(:@report_queue)
    assert_equal max_queue, queue.size

    # First few should be dropped, keeping newest
    assert_equal "resource_5", queue.first[:resource]
  end

  def test_subscribe_to_updates
    Semian::Sync::Client.subscribe_to_updates(:test_resource) do |state|
      @received_states << state
    end

    # Simulate receiving a state update
    Semian::Sync::Client.handle_state_change(:test_resource, :open)

    assert_equal [:open], @received_states
  end

  def test_multiple_subscriptions
    received1 = []
    received2 = []

    Semian::Sync::Client.subscribe_to_updates(:test_resource) { |s| received1 << s }
    Semian::Sync::Client.subscribe_to_updates(:test_resource) { |s| received2 << s }

    Semian::Sync::Client.handle_state_change(:test_resource, :open)

    assert_equal [:open], received1
    assert_equal [:open], received2
  end

  def test_callback_error_doesnt_break_other_callbacks
    callback_called = false

    Semian::Sync::Client.subscribe_to_updates(:test_resource) { raise "intentional error" }
    Semian::Sync::Client.subscribe_to_updates(:test_resource) { callback_called = true }

    Semian::Sync::Client.handle_state_change(:test_resource, :open)

    assert callback_called, "Second callback should be called despite first failing"
  end

  def test_register_resource_returns_nil_when_disconnected
    refute Semian::Sync::Client.connected?

    # Should return nil when not connected (can't register)
    result = Semian::Sync::Client.register_resource(:test_resource, {
      error_threshold: 3,
      error_timeout: 10,
      success_threshold: 2,
    })

    assert_nil result, "Should return nil when not connected"
  end
end

# Integration tests following async-bus test patterns:
# Both server and client run within a single Async reactor.
# Server is started as an async task, client connects within the same reactor.
class CircuitBreakerSyncIntegrationTest < Minitest::Test
  def setup
    @original_env = ENV["SEMIAN_SYNC_ENABLED"]
    ENV["SEMIAN_SYNC_ENABLED"] = "1"
    Semian::Sync::Client.reset!
  end

  def teardown
    Semian::Sync::Client.disconnect
    Semian::Sync::Client.reset!

    if @original_env
      ENV["SEMIAN_SYNC_ENABLED"] = @original_env
    else
      ENV.delete("SEMIAN_SYNC_ENABLED")
    end
  end

  def test_client_connects_to_server
    connected = false

    Dir.mktmpdir do |dir|
      socket_path = File.join(dir, "semian.sock")

      Async do |task|
        # Create server components directly (following async-bus pattern)
        # Pre-bind the endpoint to ensure socket is ready before client connects
        endpoint = IO::Endpoint.unix(socket_path)
        bound_endpoint = endpoint.bound

        bus_server = Async::Bus::Server.new(bound_endpoint)
        controller = Semian::Sync::CircuitBreakerController.new
        controller.register_resource(:test_resource, error_threshold: 3, error_timeout: 5, success_threshold: 2)

        # Start server as async task within the same reactor
        server_task = task.async do
          bus_server.accept do |connection|
            connection.bind(:circuit_breaker, controller)
          end
        end

        # Small yield to let server start accepting
        sleep(0.01)

        # Configure client
        Semian::Sync::Client.configure(socket_path)

        # Trigger connection by calling get_state (which calls ensure_connection)
        Semian::Sync::Client.get_state(:test_resource)

        # Check connection status
        connected = Semian::Sync::Client.connected?

        # Clean up
        server_task.stop
        bound_endpoint.close
      end
    end

    assert connected, "Client should be connected to server"
  end

  def test_client_receives_state_broadcasts
    received_states = []

    Dir.mktmpdir do |dir|
      socket_path = File.join(dir, "semian.sock")

      Async do |task|
        # Create server components with pre-bound endpoint
        endpoint = IO::Endpoint.unix(socket_path)
        bound_endpoint = endpoint.bound

        bus_server = Async::Bus::Server.new(bound_endpoint)
        controller = Semian::Sync::CircuitBreakerController.new
        controller.register_resource(:test_resource, error_threshold: 3, error_timeout: 5, success_threshold: 2)

        # Start server as async task
        server_task = task.async do
          bus_server.accept do |connection|
            connection.bind(:circuit_breaker, controller)
          end
        end

        # Small yield to let server start
        sleep(0.01)

        # Subscribe to updates before connecting
        Semian::Sync::Client.subscribe_to_updates(:test_resource) do |state|
          received_states << state
        end

        # Configure client and trigger connection
        Semian::Sync::Client.configure(socket_path)

        # Report errors (this triggers connection via ensure_connection)
        now = Time.now.to_f
        3.times do |i|
          Semian::Sync::Client.report_error_async(:test_resource, now + i)
        end

        # Verify connected after reporting
        assert Semian::Sync::Client.connected?, "Client should be connected"

        # Small yield to allow state change notification to propagate
        sleep(0.01)

        # Clean up
        server_task.stop
        bound_endpoint.close
      end
    end

    assert_includes received_states, :open, "Client should have received open state"
  end

  def test_client_queues_when_server_unavailable
    queued = false

    Dir.mktmpdir do |dir|
      socket_path = File.join(dir, "semian.sock")

      Async do
        # Configure client with non-existent socket
        Semian::Sync::Client.configure(socket_path)

        # Should not be connected (no server)
        refute Semian::Sync::Client.connected?

        # Report should be queued, not fail
        Semian::Sync::Client.report_error_async(:test_resource, Time.now.to_f)

        # Check queue
        queue = Semian::Sync::Client.instance_variable_get(:@report_queue)
        queued = queue.size == 1 && queue.first[:type] == :error
      end
    end

    assert queued, "Report should be queued when server unavailable"
  end

  def test_client_registers_resource_dynamically
    registration_result = nil

    Dir.mktmpdir do |dir|
      socket_path = File.join(dir, "semian.sock")

      Async do |task|
        # Create server with NO initial resources (empty)
        endpoint = IO::Endpoint.unix(socket_path)
        bound_endpoint = endpoint.bound

        bus_server = Async::Bus::Server.new(bound_endpoint)
        controller = Semian::Sync::CircuitBreakerController.new

        # Verify server starts empty
        assert_equal 0, controller.resources.size

        # Start server as async task
        server_task = task.async do
          bus_server.accept do |connection|
            connection.bind(:circuit_breaker, controller)
          end
        end

        sleep(0.01)

        # Configure client and connect
        Semian::Sync::Client.configure(socket_path)

        # Register resource dynamically via client
        registration_result = Semian::Sync::Client.register_resource(:dynamic_mysql_shard, {
          error_threshold: 6,
          error_timeout: 45,
          success_threshold: 2,
        })

        # Verify resource was registered on server
        assert controller.resources.key?(:dynamic_mysql_shard), "Resource should be registered on server"
        assert_equal :closed, controller.resources[:dynamic_mysql_shard][:state]
        assert_equal 6, controller.resources[:dynamic_mysql_shard][:error_threshold]

        # Clean up
        server_task.stop
        bound_endpoint.close
      end
    end

    # Verify registration result
    refute_nil registration_result
    assert registration_result[:registered], "Should report as newly registered"
    assert_equal "closed", registration_result[:state]
  end

  def test_multiple_clients_can_register_same_resource
    results = []

    Dir.mktmpdir do |dir|
      socket_path = File.join(dir, "semian.sock")

      Async do |task|
        # Create server with NO initial resources
        endpoint = IO::Endpoint.unix(socket_path)
        bound_endpoint = endpoint.bound

        bus_server = Async::Bus::Server.new(bound_endpoint)
        controller = Semian::Sync::CircuitBreakerController.new

        # Start server
        server_task = task.async do
          bus_server.accept do |connection|
            connection.bind(:circuit_breaker, controller)
          end
        end

        sleep(0.01)

        # First client registers
        Semian::Sync::Client.configure(socket_path)
        result1 = Semian::Sync::Client.register_resource(:shared_resource, {
          error_threshold: 3,
          error_timeout: 10,
          success_threshold: 2,
        })
        results << result1

        # Reset client to simulate second worker
        Semian::Sync::Client.reset!
        Semian::Sync::Client.configure(socket_path)

        # Second client tries to register same resource
        result2 = Semian::Sync::Client.register_resource(:shared_resource, {
          error_threshold: 3,
          error_timeout: 10,
          success_threshold: 2,
        })
        results << result2

        # Only one resource should exist on server
        assert_equal 1, controller.resources.size

        # Clean up
        server_task.stop
        bound_endpoint.close
      end
    end

    # First registration should be new, second should be existing
    assert results[0][:registered], "First registration should be new"
    refute results[1][:registered], "Second registration should find existing"
  end
end
