# frozen_string_literal: true

require "test_helper"
require "semian/mysql2"

class TestErrorRateMysql2 < Minitest::Test
  OPTIONS = {
    bulkhead: false,
    error_rate_threshold: 0.75,
    minimum_request_volume: 4,
    error_timeout: 5,
    success_threshold: 1,
    force_config_validation: true,
  }.freeze

  def setup
    @resource = Semian.register(:mysql_error_rate_test, **OPTIONS)
    server = TCPServer.new("127.0.0.1", 0)
    @closed_port = server.addr[1]
    server.close
  end

  def teardown
    Semian.destroy(:mysql_error_rate_test)
  end

  def test_connection_errors_reported_after_acquire_raised_are_counted_once
    4.times do |index|
      assert_raises(Mysql2::Error::ConnectionError) { connect }
      assert_equal([0, index + 1], counts)
      assert_equal(index == 3, @resource.open?)
    end
    assert_raises(Mysql2::CircuitOpenError) { connect }
  end

  def test_connection_errors_inside_an_acquire_of_the_same_resource_do_not_hide_its_success
    4.times do
      @resource.acquire { assert_raises(Mysql2::Error::ConnectionError) { connect } }
    end

    assert_equal([4, 4], counts)
    refute_predicate(@resource, :open?)
  end

  private

  def connect
    Mysql2::Client.new(host: "127.0.0.1", port: @closed_port, connect_timeout: 1, semian: OPTIONS.merge(name: "error_rate_test"))
  end

  def counts
    @resource.circuit_breaker.instance_variable_get(:@outcomes).counts
  end
end
