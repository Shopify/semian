require 'test_helper'
require 'grpc'
require 'grpc_server'
require 'route_guide_services_pb'
include Routeguide

class TestSimpleGRPC < Minitest::Test
  def setup
    thr = Thread.new { GRPCServer.start }
  end

  def test_something
    stub = RouteGuide::Stub.new('localhost:50051', :this_channel_is_insecure)

    error = assert_raises ::GRPC::BadStatus do
      run_get_feature_expect_error(stub)
    end
    assert_equal :"grpc_localhost:50051", error.semian_identifier
  end

  def run_get_feature_expect_error(stub)
    resp = stub.get_feature(Point.new)
  end
end
