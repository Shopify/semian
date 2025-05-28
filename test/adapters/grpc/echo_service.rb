# frozen_string_literal: true

# A test service with an echo implementation.
class EchoMsg
  class << self
    def unmarshal(_o)
      EchoMsg.new
    end
  end
end

class EchoService
  include GRPC::GenericService
  rpc :an_rpc, EchoMsg, EchoMsg
  rpc :a_client_streaming_rpc, stream(EchoMsg), EchoMsg
  rpc :a_server_streaming_rpc, EchoMsg, stream(EchoMsg)
  rpc :a_bidi_rpc, stream(EchoMsg), stream(EchoMsg)
  attr_reader :received_md

  def initialize(**kw)
    @trailing_metadata = kw
    @received_md = []
  end

  def an_rpc(req, call)
    GRPC.logger.info("echo service received a request")
    call.output_metadata.update(@trailing_metadata)
    @received_md << call.metadata unless call.metadata.nil?
    req
  end

  def a_client_streaming_rpc(call)
    # iterate through requests so call can complete
    call.output_metadata.update(@trailing_metadata)
    call.each_remote_read.each do |r|
      GRPC.logger.info(r)
    end
    EchoMsg.new
  end

  def a_server_streaming_rpc(_req, call)
    call.output_metadata.update(@trailing_metadata)
    [EchoMsg.new, EchoMsg.new]
  end

  def a_bidi_rpc(requests, call)
    call.output_metadata.update(@trailing_metadata)
    requests.each do |r|
      GRPC.logger.info(r)
    end
    [EchoMsg.new, EchoMsg.new]
  end
end

EchoStub = EchoService.rpc_stub_class

class EchoStubReturnOp < EchoStub
  # https://github.com/grpc/grpc/blob/v1.46.3/src/ruby/lib/grpc/generic/service.rb#L157-L159
  def initialize(host, creds, **kw)
    @default_metadata = { return_op: true }
    super
  end

  # https://github.com/grpc/grpc/blob/v1.46.3/src/ruby/lib/grpc/generic/service.rb#L168-L188
  def an_rpc(req, metadata = {})
    super(req, @default_metadata.merge(metadata))
  end

  def a_client_streaming_rpc(reqs, metadata = {})
    super(reqs, @default_metadata.merge(metadata))
  end

  def a_server_streaming_rpc(req, metadata = {}, &blk)
    super(req, @default_metadata.merge(metadata), &blk)
  end

  def a_bidi_rpc(reqs, metadata = {}, &blk)
    super(reqs, @default_metadata.merge(metadata), &blk)
  end
end
