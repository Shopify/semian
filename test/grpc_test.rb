require 'test_helper'
require 'grpc'
require 'minitest'
require 'mocha/minitest'
require 'echo_service'

class TestGRPC < Minitest::Test
  ERROR_THRESHOLD = 3
  SEMIAN_OPTIONS = {
    name: :testing,
    tickets: 1,
    timeout: 0,
    error_threshold: ERROR_THRESHOLD,
    success_threshold: 2,
    error_timeout: 2,
  }

  def setup
    build_rpc_server
    @interceptor = Semian::GRPC::Interceptor.new(@host, SEMIAN_OPTIONS)
    @stub = build_insecure_stub(EchoStub, opts: {interceptors: [@interceptor]})
  end

  def test_semian_identifier
    assert_equal :"grpc_#{@host}", @interceptor.semian_identifier
  end

  def test_errors_are_tagged_with_the_resource_identifier
    GRPC::ActiveCall.any_instance.stubs(:request_response).raises(::GRPC::Unavailable)
    error = assert_raises ::GRPC::Unavailable do
      @stub.an_rpc(EchoMsg.new)
    end
    assert_equal :"grpc_#{@host}", error.semian_identifier
  end

  def test_rpc_server
    run_services_on_server(@server, services: [EchoService]) do
      GRPC::ActiveCall.any_instance.expects(:request_response)
      @stub.an_rpc(EchoMsg.new)
    end
  end

  def test_open_circuit_error
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

  def test_wip_timeout
    hostname ||= "0.0.0.0"
    build_rpc_server
    toxic_port ||= @port + 1

    @interceptor = Semian::GRPC::Interceptor.new(@host, SEMIAN_OPTIONS)
    Toxiproxy.populate([
      {
        name: 'semian_test_grpc',
        upstream: "#{hostname}:#{@port}",
        listen: "#{hostname}:#{@port + 1}",
      },
    ])

    @stub = build_insecure_stub(EchoStub, host: "0.0.0.0:#{@port + 1}", opts: {interceptors: [@interceptor]})

    run_services_on_server(@server, services: [EchoService]) do
      Toxiproxy["semian_test_grpc"].downstream(:latency, latency: 5000).apply do
        @stub.an_rpc(EchoMsg.new)
      end
    end
  end

  private

  def build_insecure_stub(klass, host: nil, opts: nil)
    host ||= @host
    opts ||= @client_opts
    klass.new(host, :this_channel_is_insecure, **opts)
  end

  def build_rpc_server(server_opts: {}, client_opts: {})
    @server = new_rpc_server_for_testing({poll_period: 1}.merge(server_opts))
    @port = @server.add_http2_port('0.0.0.0:0', :this_port_is_insecure)
    @host = "0.0.0.0:#{@port}"
    @client_opts = client_opts
    @server
  end

  def new_rpc_server_for_testing(server_opts = {})
    server_opts[:server_args] ||= {}
    update_server_args_hash(server_opts[:server_args])
    GRPC::RpcServer.new(**server_opts)
  end

  def update_server_args_hash(server_args)
    so_reuseport_arg = 'grpc.so_reuseport'
    unless server_args[so_reuseport_arg].nil?
      fail 'Unexpected. grpc.so_reuseport already set.'
    end
    # Run tests without so_reuseport to eliminate the chance of
    # cross-talk.
    server_args[so_reuseport_arg] = 0
  end

  def run_services_on_server(server, services: [])
    services.each do |s|
      server.handle(s)
    end
    t = Thread.new { server.run }
    server.wait_till_running

    yield

    server.stop
    t.join
  end
end
