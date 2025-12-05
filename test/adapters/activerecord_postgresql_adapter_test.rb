# frozen_string_literal: true

require "test_helper"
require "semian/activerecord_postgresql_adapter"
require "adapters/activerecord_adapter_shared_tests"

module ActiveRecord
  module ConnectionAdapters
    class ActiveRecordPostgreSQLAdapterTest < Minitest::Test
      include BackgroundHelper
      include ActiveRecordAdapterSharedTests

      def setup
        super
        @configuration = {
          adapter: "postgresql",
          username: "postgres",
          password: "root",
          host: toxyproxy_host,
          port: toxyproxy_port,
          connect_timeout: 2,
          semian: SEMIAN_OPTIONS,
        }
        @adapter = new_adapter
        Semian.destroy(:postgresql_testing)
      end

      def test_with_resource_timeout_calls_through
        @adapter.with_resource_timeout(rand(0.1..0.5)) do
          assert_equal("2", @adapter.raw_connection.conninfo_hash.fetch(:connect_timeout))
        end
      end

      private

      def sleep_query(seconds)
        "SELECT pg_sleep(#{seconds})"
      end

      def adapter_class
        PostgreSQLAdapter
      end

      def adapter_name
        :postgresql_adapter
      end

      def adapter_default_port
        5432
      end

      def adapter_identifier_prefix
        :postgresql
      end

      def adapter_resource
        Semian[:postgresql_testing]
      end

      def toxyproxy_port
        SemianConfig["postgresql_toxiproxy_port"]
      end

      def toxyproxy_resource
        Toxiproxy[:semian_test_postgresql]
      end
    end
  end
end
