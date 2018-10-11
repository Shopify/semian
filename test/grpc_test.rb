require 'test_helper'
require 'grpc'
require 'google/protobuf'

class TestGRPC < Minitest::Test
  OK = GRPC::Core::StatusCodes::OK
  INTERNAL = GRPC::Core::StatusCodes::INTERNAL

  SEMIAN_OPTIONS = {
    name: :testing,
    tickets: 1,
    timeout: 0,
    error_threshold: 2,
    success_threshold: 2,
    error_timeout: 2,
  }

  def setup
    @server_port = create_test_server
    @sent_msg, @resp = 'a_msg', 'a_reply'
    @replys = Array.new(3) { |i| 'reply_' + (i + 1).to_s }
    @pass = OK
    @method = 'an_rpc_method'
    @metadata = { k1: 'v1', k2: 'v2' }
    @fail = INTERNAL
    @pass_through = proc { |x| x }
    @ch = GRPC::Core::Channel.new("0.0.0.0:#{@server_port}", nil, :this_channel_is_insecure)
    # @pass_through = proc { |x| x }
    # host = '0.0.0.0:0'
    # @server = new_core_server_for_testing(nil)
    # @server_port = @server.add_http2_port(host, :this_port_is_insecure)
    # @server.start
    # @ch = ::GRPC::Core::Channel.new("0.0.0.0:#{@server_port}", nil, :this_channel_is_insecure)
  end

  def teardown
  end

  def test_semian_identifier
    host = "localhost:#{@server_port}"
    th = run_request_response(@sent_msg, @resp, @fail)
    stub = GRPC::ClientStub.new(host, :this_channel_is_insecure)

    assert_equal :"grpc#{host}", stub.semian_identifier
  end

  def test_active_call
    skip
    active_call
  end

  def test_send_a_request_to_receive_a_reply
    host = "localhost:#{@server_port}"
    th = run_server_streamer(@sent_msg, @replys, @pass)
    stub = GRPC::ClientStub.new(host, :this_channel_is_insecure)
    assert stub.semian_identifier
    response = get_responses(stub)
    assert response.to_a == @replys
    th.join
  end

  def test_grpc_raises_an_error
    host = "localhost:#{@server_port}"
    th = run_request_response(@sent_msg, @resp, @fail)
    stub = GRPC::ClientStub.new(host, :this_channel_is_insecure)
    assert_raises ::GRPC::BadStatus do
      get_response(stub)
    end
    th.join
  end

  private

  def create_test_server
    @server = new_core_server_for_testing(nil)
    @server.add_http2_port('0.0.0.0:0', :this_port_is_insecure)
  end

  def new_core_server_for_testing(server_args)
    server_args.nil? && server_args = {}
    update_server_args_hash(server_args)
    GRPC::Core::Server.new(server_args)
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

  def run_server_streamer(expected_input, replys, status,
                          expected_metadata: {},
                          server_initial_md: {},
                          server_trailing_md: {})
    wanted_metadata = expected_metadata.clone
    wakey_thread do |notifier|
      c = expect_server_to_be_invoked(
        notifier, metadata_to_send: server_initial_md)
      wanted_metadata.each do |k, v|
        # expect(c.metadata[k.to_s]).to eq(v)
      end
      # expect(c.remote_read).to eq(expected_input)
      replys.each { |r| c.remote_send(r) }
      c.send_status(status, status == @pass ? 'OK' : 'NOK', true,
                    metadata: server_trailing_md)
      close_active_server_call(c)
    end
  end

  def wakey_thread(&blk)
    n = GRPC::Notifier.new
    t = Thread.new do
      blk.call(n)
    end
    t.abort_on_exception = true
    n.wait
    t
  end

  def expect_server_to_be_invoked(notifier, metadata_to_send: nil)
    @server.start
    notifier.notify(nil)
    recvd_rpc = @server.request_call
    recvd_call = recvd_rpc.call
    recvd_call.metadata = recvd_rpc.metadata
    recvd_call.run_batch(::GRPC::Core::CallOps::SEND_INITIAL_METADATA => metadata_to_send)
    GRPC::ActiveCall.new(recvd_call, noop, noop, ::GRPC::Core::TimeConsts::INFINITE_FUTURE,
                         metadata_received: true)
  end

  def get_responses(stub, unmarshal: noop)
    e = stub.server_streamer(@method, @sent_msg, noop, unmarshal, metadata: @metadata)
    assert e.class == Enumerator
    e
  end

  def get_response(stub, credentials: nil)
    GRPC.logger.info(credentials.inspect)
    stub.request_response(@method, @sent_msg, noop, noop,
                          metadata: @metadata,
                          credentials: credentials)
  end

  def noop
    proc { |x| x }
  end

  def close_active_server_call(active_server_call)
    active_server_call.send(:set_input_stream_done)
    active_server_call.send(:set_output_stream_done)
  end

  def run_request_response(expected_input, resp, status,
                           expected_metadata: {},
                           server_initial_md: {},
                           server_trailing_md: {})
    wanted_metadata = expected_metadata.clone
    wakey_thread do |notifier|
      c = expect_server_to_be_invoked(
        notifier, metadata_to_send: server_initial_md)
      # expect(c.remote_read).to eq(expected_input)
      wanted_metadata.each do |k, v|
        # expect(c.metadata[k.to_s]).to eq(v)
      end
      c.remote_send(resp)
      c.send_status(status, status == @pass ? 'OK' : 'NOK', true,
                    metadata: server_trailing_md)
      close_active_server_call(c)
    end
  end

  def active_call(semian_options = {})
    call = make_test_call
    @client_call = GRPC::ActiveCall.new(
      call,
      @pass_through,
      @pass_through,
      deadline,
      semian: SEMIAN_OPTIONS,
    )
  end

  def make_test_call
    @ch.create_call(nil, nil, '/method', nil, deadline)
  end

  def deadline
    Time.now + 2
  end
end