require 'test_helper'
require 'grpc'
require 'minitest'
require 'mocha/minitest'
require 'echo_service'

class TestGRPC < Minitest::Test
  ERROR_THRESHOLD = 1
  SEMIAN_OPTIONS = {
    name: :testing,
    tickets: 1,
    timeout: 0,
    error_threshold: ERROR_THRESHOLD,
    success_threshold: 1,
    error_timeout: 10,
  }

  DEFAULT_SEMIAN_CONFIGURATION = proc do |host|
    next nil if host == SemianConfig['toxiproxy_upstream_host'] && port == SemianConfig['toxiproxy_upstream_port'] # disable if toxiproxy
    SEMIAN_OPTIONS.merge(name: host)
  end

  def setup
    Semian::GRPC.instance_variable_set(:@semian_configuration, nil)
    build_rpc_server
    Semian::GRPC.semian_configuration = DEFAULT_SEMIAN_CONFIGURATION
    @stub = build_insecure_stub(EchoStub)
  end

  def teardown
    Semian.reset!
    @server.stop if @server.running_state == :running
  end

  def test_semian_identifier
    assert_equal @host, @stub.semian_identifier
  end

  def test_errors_are_tagged_with_the_resource_identifier
    GRPC::ActiveCall.any_instance.stubs(:request_response).raises(::GRPC::Unavailable)
    error = assert_raises ::GRPC::Unavailable do
      @stub.an_rpc(EchoMsg.new)
    end
    assert_equal @host, error.semian_identifier
  end

  def test_rpc_server
    run_services_on_server(@server, services: [EchoService]) do
      GRPC::ActiveCall.any_instance.expects(:request_response)
      @stub.an_rpc(EchoMsg.new)
    end
  end

  def test_unavailable_server_opens_the_circuit
    GRPC::ActiveCall.any_instance.stubs(:request_response).raises(::GRPC::Unavailable)
    ERROR_THRESHOLD.times do
      assert_raises ::GRPC::Unavailable do
        @stub.an_rpc(EchoMsg.new)
      end
    end
    assert_raises GRPC::CircuitOpenError do
      @stub.an_rpc(EchoMsg.new)
    end
  end

  def test_timeout_opens_the_circuit
    stub = build_insecure_stub(EchoStub, host: "#{@hostname}:#{@port + 1}", opts: {timeout: 0.1})
    run_services_on_server(@server, services: [EchoService]) do
      Toxiproxy['semian_test_grpc'].downstream(:latency, latency: 1000).apply do
        ERROR_THRESHOLD.times do
          assert_raises GRPC::DeadlineExceeded do
            stub.an_rpc(EchoMsg.new)
          end
        end
      end

      Toxiproxy['semian_test_grpc'].downstream(:latency, latency: 1000).apply do
        assert_raises GRPC::CircuitOpenError do
          stub.an_rpc(EchoMsg.new)
        end
      end
    end
  end

  def test_instrumentation
    notified = false
    subscriber = Semian.subscribe do |event, resource, scope, adapter|
      next if event == :lru_hash_gc
      notified = true
      assert_equal :success, event
      assert_equal Semian[@host], resource
      assert_equal :request_response, scope
      assert_equal :grpc, adapter
    end

    run_services_on_server(@server, services: [EchoService]) do
      GRPC::ActiveCall.any_instance.expects(:request_response)
      @stub.an_rpc(EchoMsg.new)
    end

    assert notified, 'No notifications has been emitted'
  ensure
    Semian.unsubscribe(subscriber)
  end

  def test_circuit_breaker_on_client_streamer
    stub = build_insecure_stub(EchoStub, host: "0.0.0.1:0")
    requests = [EchoMsg.new, EchoMsg.new]
    open_circuit!(stub, :a_client_streaming_rpc, requests)

    assert_raises GRPC::CircuitOpenError do
      stub.a_client_streaming_rpc(requests)
    end
  end

  def test_circuit_breaker_on_server_streamer
    stub = build_insecure_stub(EchoStub, host: "0.0.0.1:0")
    request = EchoMsg.new
    open_circuit!(stub, :a_server_streaming_rpc, request)

    assert_raises GRPC::CircuitOpenError do
      stub.a_server_streaming_rpc(request)
    end
  end

  def test_circuit_breaker_on_bidi_streamer
    stub = build_insecure_stub(EchoStub, host: "0.0.0.1:0")
    requests = [EchoMsg.new, EchoMsg.new]
    open_circuit!(stub, :a_bidi_rpc, requests)

    assert_raises GRPC::CircuitOpenError do
      stub.a_bidi_rpc(requests)
    end
  end

  def test_bulkheads_tickets_are_working
    options = proc do |host|
      {
        tickets: 1,
        success_threshold: 1,
        error_threshold: 3,
        error_timeout: 10,
        name: "#{host}",
      }
    end
    Semian::GRPC.instance_variable_set(:@semian_configuration, nil)
    Semian::GRPC.semian_configuration = options
    build_rpc_server

    run_services_on_server(@server, services: [EchoService]) do
      stub1 = build_insecure_stub(EchoStub)
      stub1.semian_resource.acquire do
        stub2 = build_insecure_stub(EchoStub, host: "0.0.0.1")
        stub2.semian_resource.acquire do
          assert_raises GRPC::ResourceBusyError do
            stub2.an_rpc(EchoMsg.new)
          end
        end
      end
    end
  end

  private

  def open_circuit!(stub, method, args)
    ERROR_THRESHOLD.times do
      assert_raises GRPC::Unavailable do
        stub.send(method, args)
      end
    end
  end

  def build_insecure_stub(klass, host: nil, opts: nil)
    host ||= @host
    opts ||= @client_opts
    klass.new(host, :this_channel_is_insecure, **opts)
  end

  def build_rpc_server(server_opts: {}, client_opts: {})
    @hostname = SemianConfig['grpc_host']
    @server = new_rpc_server_for_testing({poll_period: 1}.merge(server_opts))
    @port = @server.add_http2_port("#{@hostname}:#{SemianConfig['grpc_port']}", :this_port_is_insecure)
    @host = "#{@hostname}:#{@port}"
    @client_opts = client_opts
    @server
  end

  def new_rpc_server_for_testing(server_opts = {})
    server_opts[:server_args] ||= {}
    GRPC::RpcServer.new(**server_opts)
  end

  def run_services_on_server(server, services: [])
    services.each do |s|
      server.handle(s)
    end
    begin
      t = Thread.new { server.run }
      server.wait_till_running

      yield
    ensure
      server.stop
      t.join
    end
  end
end
