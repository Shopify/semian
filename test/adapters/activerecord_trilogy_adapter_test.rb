# frozen_string_literal: true

require "test_helper"
require "semian/activerecord_trilogy_adapter"
require "semian/activerecord_trilogy_adapter"
require "adapters/activerecord_adapter_shared_tests"

module ActiveRecord
  module ConnectionAdapters
    class ActiveRecordTrilogyAdapterTest < Minitest::Test
      include BackgroundHelper
      include ActiveRecordAdapterSharedTests

      def setup
        super
        @configuration = {
          adapter: "trilogy",
          username: "root",
          password: "root",
          ssl: true,
          ssl_mode: 3,
          host: toxyproxy_host,
          port: toxyproxy_port,
          read_timeout: 2,
          write_timeout: 2,
          semian: SEMIAN_OPTIONS,
        }
        @adapter = new_adapter
        Semian.destroy(:mysql_testing)
      end

      def teardown
        super
        @adapter.disconnect!
      end

      def test_with_resource_timeout
        assert_equal(2.0, @adapter.raw_connection.read_timeout)
        @adapter.with_resource_timeout(0.5) do
          assert_equal(0.5, @adapter.raw_connection.read_timeout)
        end
        assert_equal(2.0, @adapter.raw_connection.read_timeout)
      end

      def test_read_timeout_error_opens_the_circuit
        ERROR_THRESHOLD.times do
          assert_raises(ActiveRecord::StatementInvalid) do
            @adapter.execute(sleep_query(5))
          end
        end

        assert_raises(adapter_class::CircuitOpenError) do
          @adapter.execute(sleep_query(5))
        end

        # After adapter_class::CircuitOpenError check regular queries are working fine.
        result = time_travel(ERROR_TIMEOUT + 1) do
          @adapter.execute("SELECT 1 + 1;")
        end

        assert_equal(2, result.first[0])
      end

      def test_changes_timeout_when_half_open_and_configured
        adapter = new_adapter(semian: SEMIAN_OPTIONS.merge(half_open_resource_timeout: 1))

        @proxy.downstream(:latency, latency: 3000).apply do
          ERROR_THRESHOLD.times do
            assert_raises(ActiveRecord::ConnectionNotEstablished) do
              adapter.execute("SELECT 1 + 1;")
            end
          end
        end

        assert_raises(adapter_class::CircuitOpenError) do
          adapter.execute("SELECT 1 + 1;")
        end

        # Circuit moves to half-open state, so 1500 of latency should result in error
        time_travel(ERROR_TIMEOUT + 1) do
          @proxy.downstream(:latency, latency: 1500).apply do
            assert_raises(ActiveRecord::ConnectionNotEstablished) do
              adapter.execute("SELECT 1 + 1;")
            end
          end
        end

        time_travel(ERROR_TIMEOUT * 2 + 1) do
          adapter.execute("SELECT 1 + 1;")
          adapter.execute("SELECT 1 + 1;")

          # Timeout has reset to the normal 2 seconds now that circuit is closed
          @proxy.downstream(:latency, latency: 1500).apply do
            adapter.execute("SELECT 1 + 1;")
          end
        end

        raw_connection = adapter.send(:raw_connection)

        assert_equal(2, raw_connection.read_timeout)
        assert_equal(2, raw_connection.write_timeout)
      end

      private

      def sleep_query(seconds)
        "SELECT sleep(#{seconds})"
      end

      def adapter_class
        TrilogyAdapter
      end

      def adapter_name
        :trilogy_adapter
      end

      def adapter_default_port
        3306
      end

      def adapter_identifier_prefix
        :mysql
      end

      def adapter_resource
        Semian[:mysql_testing]
      end

      def toxyproxy_port
        SemianConfig["mysql_toxiproxy_port"]
      end

      def toxyproxy_resource
        Toxiproxy[:semian_test_mysql]
      end
    end
  end
end
