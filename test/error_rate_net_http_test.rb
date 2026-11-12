# frozen_string_literal: true

require "test_helper"
require "semian/net_http"

class TestErrorRateNetHTTP < Minitest::Test
  include TimeHelper

  def setup
    @original = Semian::NetHTTP.semian_configuration
    Semian::NetHTTP.instance_variable_set(:@semian_configuration, nil)
    Semian::NetHTTP.semian_configuration = proc do |_, _|
      {
        name: "error_rate_test",
        bulkhead: false,
        error_rate_threshold: 0.75,
        minimum_request_volume: 4,
        error_timeout: 5,
        success_threshold: 1,
        open_circuit_server_errors: true,
        force_config_validation: true,
      }
    end
    @http = Net::HTTP.new("127.0.0.1", SemianConfig["http_port_service_a"], nil)
  end

  def teardown
    Semian.destroy("nethttp_error_rate_test")
    Semian::NetHTTP.instance_variable_set(:@semian_configuration, nil)
    Semian::NetHTTP.semian_configuration = @original
  end

  def test_server_errors_are_counted_once_without_successful_connections_diluting_the_rate
    4.times do |index|
      assert_equal("500", @http.get("/500").code)
      assert_equal([0, index + 1], counts)
      assert_equal(index == 3, @http.semian_resource.open?)
    end
    assert_raises(Net::CircuitOpenError) { @http.get("/500") }
  end

  def test_successful_responses_and_connections_count_one_success_per_request
    3.times { assert_equal("200", @http.get("/200").code) }
    assert_equal("500", @http.get("/500").code)

    assert_equal([3, 1], counts)
  end

  # Inherited from the classic breaker: a successful connection is neutral in the rate but is a half-open success.
  def test_successful_connection_counts_towards_half_open_recovery_as_in_the_classic_breaker
    4.times { @http.get("/500") }

    assert_predicate(@http.semian_resource, :open?)

    time_travel(6) do
      assert_equal("500", @http.get("/500").code)

      assert_predicate(@http.semian_resource, :closed?)
      assert_equal([0, 1], counts)
    end
  end

  private

  def counts
    @http.semian_resource.circuit_breaker.instance_variable_get(:@outcomes).counts
  end
end
