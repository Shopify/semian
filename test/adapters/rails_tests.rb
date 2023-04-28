# frozen_string_literal: true

require "test_helper"
require "active_record"
require "semian/rails"

module RailsTests
  SUCCESS_THRESHOLD = 2
  ERROR_THRESHOLD = 1
  ERROR_TIMEOUT = 5
  SEMIAN_OPTIONS = {
    name: :testing,
    tickets: 1,
    timeout: 0,
    error_threshold: ERROR_THRESHOLD,
    success_threshold: SUCCESS_THRESHOLD,
    error_timeout: ERROR_TIMEOUT,
  }

  def setup
    @config = {
      adapter: @adapter,
      connect_timeout: 2,
      read_timeout: 2,
      write_timeout: 2,
      reconnect: true,
      prepared_statements: false,
      host: SemianConfig["toxiproxy_upstream_host"],
      port: SemianConfig["mysql_toxiproxy_port"],
      semian: SEMIAN_OPTIONS,
    }

    ActiveRecord::Base.establish_connection(@config)

    @connection = ActiveRecord::Base.connection
    @resource = @connection.semian_resource
    @circuit_breaker = @resource.circuit_breaker
  end

  def test_connection_has_a_semian_resource
    assert_semian_resource
  end

  def test_semian_resource_is_available_after_disconnect
    assert_semian_resource_reconnects do
      @connection.disconnect!
    end
  end

  def test_semian_resource_is_available_after_reset
    assert_semian_resource_reconnects do
      @connection.reset!
    end
  end

  def test_semian_resource_is_available_after_reconnect
    assert_semian_resource_reconnects do
      @connection.reconnect!
    end
  end

  private

  def assert_semian_resource_reconnects(&block)
    assert_semian_resource

    yield

    assert_semian_resource
  end

  def assert_semian_resource
    assert_equal(SEMIAN_OPTIONS, @connection.instance_variable_get(:@config)[:semian])
    assert(@resource, "expected semian_resource to be available on @connection")
    assert_equal(:mysql_testing, @resource.name)
    assert_equal(SUCCESS_THRESHOLD, @circuit_breaker.instance_variable_get(:@success_count_threshold))
    assert_equal(ERROR_THRESHOLD, @circuit_breaker.instance_variable_get(:@error_count_threshold))
    assert_equal(ERROR_TIMEOUT, @circuit_breaker.instance_variable_get(:@error_timeout))
  end
end
