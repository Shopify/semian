require 'test_helper'
require 'grpc'
require 'grpc_server'
require 'route_guide_services_pb'
include Routeguide

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
    thr = Thread.new { GRPCServer.start }
    @stub = RouteGuide::Stub.new('localhost:50051', :this_channel_is_insecure, SEMIAN_OPTIONS)
  end

  def test_semian_identifier
    error = assert_raises ::GRPC::BadStatus do
      run_get_feature_expect_error(@stub)
    end

    assert_equal :"grpc_localhost:50051", error.semian_identifier
  end

  def test_circuit_open
    ERROR_THRESHOLD.times do
      assert_raises ::GRPC::BadStatus do
        run_get_feature_expect_error(@stub)
      end
    end

    assert_raises GRPC::CircuitOpenError do
      run_get_feature_expect_error(@stub)
    end
  end

  def run_get_feature_expect_error(stub)
    resp = stub.get_feature(Point.new)
  end
end
