# A test service with an echo implementation.
class EchoMsg
  def self.marshal(_o)
    ''
  end

  def self.unmarshal(_o)
    EchoMsg.new
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
    GRPC.logger.info('echo service received a request')
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
