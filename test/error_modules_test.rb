# frozen_string_literal: true

require "test_helper"
require "semian/activerecord_trilogy_adapter"
require "semian/activerecord_postgresql_adapter"
require "semian/net_http"
require "semian/grpc"
require "semian/redis"
require "semian/redis_client"
require "semian/mysql2"

class ErrorModulesTest < Minitest::Test
  ERRORS = [
    ActiveRecord::ConnectionAdapters::TrilogyAdapter,
    ActiveRecord::ConnectionAdapters::PostgreSQLAdapter,
    Net,
    GRPC,
    Redis,
    RedisClient,
    Mysql2,
  ].map { |mod| [mod.const_get(:ResourceBusyError), mod.const_get(:CircuitOpenError)] }

  def test_adapter_errors_rescue
    ERRORS.each do |busy_error, circuit_error|
      assert_kind_of(busy_error.new, Semian::AdapterResourceBusyError)
      assert_kind_of(circuit_error.new, Semian::AdapterCircuitOpenError)
    end
  end

  def test_markers_do_not_match_unrelated_activerecord_errors
    [ActiveRecord::RecordNotFound, ActiveRecord::StatementInvalid, ActiveRecord::AdapterTimeout].each do |record_error|
      error = record_error.new

      refute_kind_of(error.is_a?(Semian::AdapterResourceBusyError))
      refute_kind_of(error.is_a?(Semian::AdapterCircuitOpenError))
    end
  end
end
