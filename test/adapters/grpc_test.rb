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

class TestGRPCErrorRate < Minitest::Test
  THREAD_SAFETY_DISABLED = nil
  RETURN_OP_RPCS = {
    an_rpc: EchoMsg.new,
    a_client_streaming_rpc: [EchoMsg.new, EchoMsg.new],
    a_server_streaming_rpc: EchoMsg.new,
    a_bidi_rpc: [EchoMsg.new, EchoMsg.new],
  }.freeze

  def setup
    @original = Semian::GRPC.semian_configuration
    Semian::GRPC.instance_variable_set(:@semian_configuration, nil)
    Semian::GRPC.semian_configuration = proc do |host|
      {
        name: host,
        bulkhead: false,
        error_rate_threshold: 0.75,
        minimum_request_volume: 4,
        error_timeout: 5,
        success_threshold: 1,
        thread_safety_disabled: self.class::THREAD_SAFETY_DISABLED,
        dynamic: @dynamic,
      }.compact
    end
    @stubs = []
  end

  def teardown
    @stubs.each do |stub|
      stub.instance_variable_get(:@ch).close
      Semian.destroy(stub.semian_identifier)
    end
    if @server
      @server.stop
      @server_thread.kill unless @server_thread.join(5)
    end
    Semian::GRPC.instance_variable_set(:@semian_configuration, nil)
    Semian::GRPC.semian_configuration = @original
  end

  RETURN_OP_RPCS.each do |rpc, request|
    define_method("test_failed_#{rpc}_operations_open_the_circuit_at_the_error_rate_threshold") do
      stub = build_stub(EchoStubReturnOp, refused_host)
      created_while_closed = stub.send(rpc, request)

      4.times do |index|
        operation = stub.send(rpc, request)

        assert_equal([0, index], counts(stub))
        assert_refused { operation.execute }
        assert_equal([0, index + 1], counts(stub))
        assert_equal(index == 3, stub.semian_resource.open?)
      end
      assert_raises(GRPC::CircuitOpenError) { stub.send(rpc, request) }
      assert_raises(GRPC::CircuitOpenError) { created_while_closed.execute }
      assert_equal([0, 4], counts(stub))
    end

    define_method("test_successful_#{rpc}_operations_count_one_success_each") do
      stub = build_stub(EchoStubReturnOp, live_host)

      3.times do |index|
        operation = stub.send(rpc, request)

        assert_equal([index, 0], counts(stub))
        Array(operation.execute)

        assert_equal([index + 1, 0], counts(stub))
      end
    end
  end

  def test_operations_that_are_never_executed_are_neutral
    stub = build_stub(EchoStubReturnOp, live_host)
    RETURN_OP_RPCS.each { |rpc, request| stub.send(rpc, request) }

    assert_equal([0, 0], counts(stub))
  end

  def test_failed_operation_creation_counts_one_failure
    stub = build_stub(EchoStubReturnOp, live_host)
    GRPC::ActiveCall.any_instance.stubs(:operation).raises(GRPC::Unavailable)

    assert_raises(GRPC::Unavailable) { stub.an_rpc(EchoMsg.new) }
    assert_equal([0, 1], counts(stub))
  end

  def test_dynamic_resource_defers_the_outcome_of_an_operation_to_its_execution
    @dynamic = true
    stub = build_stub(EchoStubReturnOp, refused_host)
    operation = stub.an_rpc(EchoMsg.new)

    assert_nil(stub.instance_variable_get(:@semian_resource))
    assert_equal([0, 0], counts(stub))
    assert_refused { operation.execute }
    assert_equal([0, 1], counts(stub))
  end

  def test_operations_are_unprotected_when_semian_is_disabled
    ENV["SEMIAN_DISABLED"] = "1"
    stub = build_stub(EchoStubReturnOp, live_host)

    assert_instance_of(Semian::UnprotectedResource, stub.semian_resource)
    assert_instance_of(EchoMsg, stub.an_rpc(EchoMsg.new).execute)
  ensure
    ENV.delete("SEMIAN_DISABLED")
  end

  def test_calls_that_are_not_deferred_count_one_outcome_each
    live = build_stub(EchoStub, live_host)
    refused = build_stub(EchoStub, refused_host)

    3.times { live.an_rpc(EchoMsg.new) }
    4.times do |index|
      assert_refused { refused.an_rpc(EchoMsg.new) }
      assert_equal(index == 3, refused.semian_resource.open?)
    end

    assert_equal([3, 0], counts(live))
    assert_equal([0, 4], counts(refused))
    assert_raises(GRPC::CircuitOpenError) { refused.an_rpc(EchoMsg.new) }
  end

  def test_operation_created_within_a_failed_call_of_the_same_stub_leaves_that_failure_counted
    stub = build_reentrant_stub(refused_host)

    assert_refused { stub.an_rpc(EchoMsg.new) }
    assert_equal(1, @interceptor.operations.size)
    assert_equal([0, 1], counts(stub))
  end

  def test_operation_created_within_a_successful_call_of_the_same_stub_leaves_that_success_counted
    stub = build_reentrant_stub(live_host)
    stub.an_rpc(EchoMsg.new)

    assert_equal(1, @interceptor.operations.size)
    assert_equal([1, 0], counts(stub))
  end

  def test_failure_after_the_outcome_is_deferred_counts_one_failure
    stub = build_stub(EchoStubReturnOp, live_host)

    assert_raises(GRPC::Unavailable) do
      stub.semian_resource.acquire do
        Semian::ErrorRateCircuitBreaker.defer_outcome(since: nil)
        raise GRPC::Unavailable
      end
    end
    assert_equal([0, 1], counts(stub))
  end

  def test_deferring_without_a_new_acquire_leaves_the_enclosing_outcome_counted
    stub = build_stub(EchoStubReturnOp, live_host)

    stub.semian_resource.acquire do
      Semian::ErrorRateCircuitBreaker.defer_outcome(since: Semian::ErrorRateCircuitBreaker.acquisition)
    end

    assert_equal([1, 0], counts(stub))
  end

  # The stub is held by another thread when the call starts and free by the time the call acquires, so the call
  # makes an acquire of its own: whether it defers must follow that acquire, not what the stub looked like before.
  def test_operation_created_once_another_thread_released_the_stub_defers_its_own_acquire
    stub = build_stub(EchoStubReturnOp, live_host)
    breaker = stub.semian_resource.circuit_breaker
    held, release, paused, resume = Array.new(4) { Queue.new }
    seen = {}
    stub.define_singleton_method(:acquire_semian_resource) do |**options, &block|
      next super(**options, &block) unless Thread.current[:pause_before_acquire]

      seen[:held_on_entry] = resource_already_acquired?
      paused << true
      resume.pop(timeout: 5) || raise("not resumed")
      seen[:held_on_acquire] = resource_already_acquired?
      super(**options) do
        seen[:frame] = Semian::ErrorRateCircuitBreaker.acquisition
        block.call
      end
    end
    events = []
    subscription = Semian.subscribe { |event, *| events << event }

    holder = Thread.new do
      stub.send(:acquire_semian_resource, adapter: :grpc, scope: :request_response) do
        held << true
        release.pop(timeout: 5) || raise("not released")
      end
    end

    assert(held.pop(timeout: 5))
    creator = Thread.new do
      Thread.current[:pause_before_acquire] = true
      stub.an_rpc(EchoMsg.new)
    end

    assert(paused.pop(timeout: 5))
    release << true

    assert(holder.join(5))
    assert_equal([1, 0], counts(stub))
    resume << true

    assert(creator.join(5))
    assert_equal({ held_on_entry: true, held_on_acquire: false }, seen.slice(:held_on_entry, :held_on_acquire))
    assert_same(breaker, seen[:frame][0])
    assert(seen[:frame][3])
    assert_equal([:success, :success], events)
    assert_equal([1, 0], counts(stub))

    creator.value.execute

    assert_equal([2, 0], counts(stub))
  ensure
    Semian.unsubscribe(subscription)
    [release, resume].each { |queue| queue << true }
    [holder, creator].each { |thread| thread&.join(5) || thread&.kill }
  end

  # Inherited from the classic breaker: an admitted operation is neutral in the rate but is a half-open success.
  def test_operation_creation_counts_towards_half_open_recovery_as_in_the_classic_breaker
    stub = build_stub(EchoStubReturnOp, refused_host)

    4.times { assert_refused { stub.an_rpc(EchoMsg.new).execute } }

    assert_predicate(stub.semian_resource, :open?)

    time_travel(6) do
      stub.an_rpc(EchoMsg.new)

      assert_predicate(stub.semian_resource, :closed?)
      assert_equal([0, 0], counts(stub))
    end
  end

  def test_scope_and_events_of_operations_are_unchanged
    stub = build_stub(EchoStubReturnOp, refused_host)
    stub.semian_resource
    events = []
    subscription = Semian.subscribe { |event, _, scope, adapter| events << [event, scope, adapter] }

    assert_refused { stub.an_rpc(EchoMsg.new).execute }
    assert_equal([[:success, :request_response, :grpc]] * 2, events)
  ensure
    Semian.unsubscribe(subscription)
  end

  private

  # Creates an operation on the stub that is running the intercepted call, as a reentrant client interceptor can.
  class ReentrantInterceptor < GRPC::ClientInterceptor
    attr_accessor :stub
    attr_reader :operations

    def request_response(**)
      (@operations ||= []) << stub.an_rpc(EchoMsg.new, return_op: true)
      yield
    end
  end

  def build_reentrant_stub(host)
    @interceptor = ReentrantInterceptor.new
    @interceptor.stub = build_stub(EchoStub, host, interceptors: [@interceptor])
  end

  # A refused connection surfaces as either error, depending on the platform.
  def assert_refused(&block)
    assert_raises(GRPC::Unavailable, GRPC::DeadlineExceeded, &block)
  end

  def counts(stub)
    stub.semian_resource.circuit_breaker.instance_variable_get(:@outcomes).counts
  end

  def build_stub(klass, host, **options)
    klass.new(host, :this_channel_is_insecure, timeout: 3, **options).tap { |stub| @stubs << stub }
  end

  def refused_host
    "127.0.0.1:#{TCPServer.open("127.0.0.1", 0) { |server| server.addr[1] }}"
  end

  def live_host
    @server = GRPC::RpcServer.new(poll_period: 1)
    port = @server.add_http2_port("127.0.0.1:0", :this_port_is_insecure)
    @server.handle(EchoService)
    @server_thread = Thread.new { @server.run }
    @server.wait_till_running
    "127.0.0.1:#{port}"
  end
end

class TestGRPCErrorRateWithoutThreadSafety < TestGRPCErrorRate
  THREAD_SAFETY_DISABLED = true
end
