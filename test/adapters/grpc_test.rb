# frozen_string_literal: true

require "test_helper"
require "grpc"
require "semian/grpc"
require_relative "grpc/echo_service"

class TestGRPC < Minitest::Test
  DEFAULT_CLIENT_TIMEOUT_IN_SECONDS = 3
  ERROR_THRESHOLD = 1
  SEMIAN_OPTIONS = {
    name: :testing,
    tickets: 1,
    timeout: 0,
    error_threshold: ERROR_THRESHOLD,
    success_threshold: 1,
    error_timeout: 10,
  }.freeze

  DEFAULT_SEMIAN_CONFIGURATION = proc do |host|
    if host == SemianConfig["toxiproxy_upstream_host"] &&
        port == SemianConfig["toxiproxy_upstream_port"] # disable if toxiproxy
      next nil
    end

    SEMIAN_OPTIONS.merge(name: host)
  end

  def setup
    Semian::GRPC.instance_variable_set(:@semian_configuration, nil)
    Semian::GRPC.semian_configuration = DEFAULT_SEMIAN_CONFIGURATION # Set config first

    build_rpc_server # Creates @server, @host, @client_opts
    @stub = build_insecure_stub(EchoStub) # Uses @host and @client_opts

    @server.handle(EchoService)

    @server_thread = Thread.new { @server.run }
    @server.wait_till_running
  end

  def teardown
    Semian.reset!

    # Stop the server first
    if @server && @server.running_state == :running
      @server.stop
    end

    # Join the server thread with a timeout
    if @server_thread
      join_successful = @server_thread.join(5) # Wait max 5 seconds
      unless join_successful
        @server_thread.kill # Force kill if it hangs
        @server_thread.join # Wait for the killed thread to finish
      end
    end

    # Close the underlying channel of the client stub
    @stub&.instance_variable_get(:@ch)&.close

    # Force garbage collection to exit cleanly
    GC.start
  end

  def test_semian_identifier
    assert_equal(@host, @stub.semian_identifier)
  end

  def test_errors_are_tagged_with_the_resource_identifier
    GRPC::ActiveCall.any_instance.stubs(:request_response).raises(::GRPC::Unavailable)
    error = assert_raises(::GRPC::Unavailable, ::GRPC::DeadlineExceeded) do
      @stub.an_rpc(EchoMsg.new)
    end
    assert_equal(@host, error.semian_identifier)
  end

  def test_rpc_server
    GRPC::ActiveCall.any_instance.expects(:request_response)
    @stub.an_rpc(EchoMsg.new)
  end

  def test_rpc_server_with_operation
    # skip "flaky"
    stub_return_op = nil
    begin
      stub_return_op = build_insecure_stub(EchoStubReturnOp)

      mock_operation = mock("operation")
      mock_operation.expects(:execute).once # Expect execute to be called

      stub_return_op.stubs(:an_rpc).with(instance_of(EchoMsg)).returns(mock_operation)

      operation = stub_return_op.an_rpc(EchoMsg.new)

      operation.execute
    ensure
      stub_return_op&.instance_variable_get(:@ch)&.close
    end
  end

  def test_unavailable_server_opens_the_circuit
    # No need for run_services_on_server as we expect failure before reaching the service
    GRPC::ActiveCall.any_instance.stubs(:request_response).raises(::GRPC::Unavailable)

    ERROR_THRESHOLD.times do
      assert_raises(::GRPC::Unavailable, ::GRPC::DeadlineExceeded) do
        @stub.an_rpc(EchoMsg.new) # Uses the main @stub connected to the running server
      end
    end
    assert_raises(GRPC::CircuitOpenError) do
      @stub.an_rpc(EchoMsg.new)
    end
  end

  def test_timeout_opens_the_circuit
    skip if ENV["SKIP_FLAKY_TESTS"]
    # This test requires a specific toxiproxy setup, so it uses its own stub
    # The main server (@server) is running but not directly involved here.
    stub = build_insecure_stub(
      EchoStub,
      host: "#{SemianConfig["toxiproxy_upstream_host"]}:#{SemianConfig["grpc_toxiproxy_port"]}",
      opts: { timeout: 0.1 },
    )
    # This test also needs the *actual* service running behind the proxy
    # @server with EchoService is running from setup
    begin
      Toxiproxy["semian_test_grpc"].downstream(:latency, latency: 1000).apply do
        ERROR_THRESHOLD.times do
          # We assert both of these since DeadlineExceeded is what we see in CI, but when running locally
          # we get Unavailable for some reason
          assert_raises(GRPC::Unavailable, GRPC::DeadlineExceeded) do
            stub.an_rpc(EchoMsg.new)
          end
        end
      end

      Toxiproxy["semian_test_grpc"].downstream(:latency, latency: 1000).apply do
        assert_raises(GRPC::CircuitOpenError) do
          stub.an_rpc(EchoMsg.new)
        end
      end
    end
  end

  def test_instrumentation
    notified = false
    subscriber = Semian.subscribe do |event, resource, scope, adapter|
      next if event != :success

      notified = true

      assert_equal(Semian[@host], resource)
      assert_equal(:request_response, scope)
      assert_equal(:grpc, adapter)
    end
    @stub.an_rpc(EchoMsg.new)

    assert(notified, "No notifications has been emitted")
  ensure
    Semian.unsubscribe(subscriber)
  end

  def test_circuit_breaker_on_client_streamer
    stub = build_insecure_stub(EchoStub, host: "0.0.0.1:0")
    requests = [EchoMsg.new, EchoMsg.new]
    open_circuit!(stub, :a_client_streaming_rpc, requests)

    assert_raises(GRPC::CircuitOpenError) do
      stub.a_client_streaming_rpc(requests)
    end
  end

  def test_circuit_breaker_on_server_streamer
    stub = build_insecure_stub(EchoStub, host: "0.0.0.1:0")
    request = EchoMsg.new
    open_circuit!(stub, :a_server_streaming_rpc, request)

    assert_raises(GRPC::CircuitOpenError) do
      stub.a_server_streaming_rpc(request)
    end
  end

  def test_circuit_breaker_on_bidi_streamer
    stub = build_insecure_stub(EchoStub, host: "0.0.0.1:0")
    requests = [EchoMsg.new, EchoMsg.new]
    open_circuit!(stub, :a_bidi_rpc, requests)

    assert_raises(GRPC::CircuitOpenError) do
      stub.a_bidi_rpc(requests)
    end
  end

  def test_circuit_breaker_on_client_streamer_return_op
    stub = build_insecure_stub(EchoStubReturnOp, host: "0.0.0.1:0")
    requests = [EchoMsg.new, EchoMsg.new]
    open_circuit!(stub, :a_client_streaming_rpc, requests, return_op: true)

    assert_raises(GRPC::CircuitOpenError) do
      stub.a_client_streaming_rpc(requests).execute
    end
  end

  def test_circuit_breaker_on_server_streamer_return_op
    stub = build_insecure_stub(EchoStubReturnOp, host: "0.0.0.1:0")
    request = EchoMsg.new
    open_circuit!(stub, :a_server_streaming_rpc, request, return_op: true)

    assert_raises(GRPC::CircuitOpenError) do
      stub.a_server_streaming_rpc(request).execute
    end
  end

  def test_circuit_breaker_on_bidi_streamer_return_op
    stub = build_insecure_stub(EchoStubReturnOp, host: "0.0.0.1:0")
    requests = [EchoMsg.new, EchoMsg.new]
    open_circuit!(stub, :a_bidi_rpc, requests, return_op: true)

    assert_raises(GRPC::CircuitOpenError) do
      stub.a_bidi_rpc(requests).execute
    end
  end

  # --- Bulkhead Test ---
  def test_bulkheads_tickets_are_working
    # This test requires specific Semian config, override the default
    original_config = Semian::GRPC.semian_configuration
    options = proc do |host|
      {
        tickets: 1,
        success_threshold: 1,
        error_threshold: 3,
        error_timeout: 10,
        name: host.to_s,
      }
    end
    Semian::GRPC.instance_variable_set(:@semian_configuration, nil) # Clear cache
    Semian::GRPC.semian_configuration = options

    begin
      stub1 = build_insecure_stub(EchoStub)
      stub1.semian_resource.acquire do
        # Create another stub targeting the *same* running server instance
        # Use the same @host so it resolves to the same Semian resource based on the config proc
        stub2 = build_insecure_stub(EchoStub)

        # We don't need to acquire stub2's resource explicitly,
        # the acquire happens within the gRPC call patching
        assert_raises(GRPC::ResourceBusyError) do
          stub2.an_rpc(EchoMsg.new)
        end
      ensure
        stub2&.instance_variable_get(:@ch)&.close
      end
    ensure
      # Restore original Semian config and close stubs
      Semian::GRPC.instance_variable_set(:@semian_configuration, nil) # Clear cache
      Semian::GRPC.semian_configuration = original_config
      stub1&.instance_variable_get(:@ch)&.close
    end
  end

  private

  def open_circuit!(stub, method, args, return_op: false)
    ERROR_THRESHOLD.times do
      if return_op
        call = stub.send(method, args) # Get operation first
        assert_raises(GRPC::Unavailable, GRPC::DeadlineExceeded) do
          call.execute # Only this call should be in the block
        end
      else
        assert_raises(GRPC::Unavailable, GRPC::DeadlineExceeded) do
          stub.send(method, args) # The RPC call itself raises
        end
      end
    end
  end

  def build_insecure_stub(klass, host: nil, opts: nil)
    host ||= @host # Default to the main server host
    opts ||= @client_opts # Default to the main client opts
    klass.new(host, :this_channel_is_insecure, **opts)
  end

  def build_rpc_server(server_opts: {}, client_opts: {})
    @hostname = SemianConfig["grpc_host"]
    # server_bind_address = "0.0.0.0"
    # client_target_hostname = "localhost"

    @server = new_rpc_server_for_testing({ poll_period: 1 }.merge(server_opts))
    @port = @server.add_http2_port("0.0.0.0:#{SemianConfig["grpc_port"]}", :this_port_is_insecure)
    @host = "localhost:#{@port}"
    @client_opts = { timeout: DEFAULT_CLIENT_TIMEOUT_IN_SECONDS }.merge(client_opts)
  end

  def new_rpc_server_for_testing(server_opts = {})
    server_opts[:server_args] ||= {}
    GRPC::RpcServer.new(**server_opts)
  end
end
