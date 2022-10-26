# frozen_string_literal: true

require "test_helper"
require "semian/trilogy_adapter"

module ActiveRecord
  module ConnectionAdapters
    class TrilogyAdapterTest < Minitest::Test
      ERROR_TIMEOUT = 5
      ERROR_THRESHOLD = 1
      SEMIAN_OPTIONS = {
        name: "testing",
        tickets: 1,
        timeout: 0,
        error_threshold: ERROR_THRESHOLD,
        success_threshold: 2,
        error_timeout: ERROR_TIMEOUT,
      }

      def setup
        @proxy = Toxiproxy[:semian_test_mysql]
        Semian.destroy(:trilogy_adapter_testing)

        @configuration = {
          adapter: "trilogy",
          username: "root",
          host: SemianConfig["toxiproxy_upstream_host"],
          port: SemianConfig["mysql_toxiproxy_port"],
          read_timeout: 2,
          write_timeout: 2,
          semian: SEMIAN_OPTIONS,
        }
        @adapter = trilogy_adapter
      end

      def test_semian_identifier
        assert_equal(:"trilogy_adapter_testing", @adapter.semian_identifier)

        adapter = trilogy_adapter(host: "127.0.0.1", semian: { name: nil })
        assert_equal(:"trilogy_adapter_127.0.0.1:13306", adapter.semian_identifier)

        adapter = trilogy_adapter(host: "example.com", port: 42, semian: { name: nil })
        assert_equal(:"trilogy_adapter_example.com:42", adapter.semian_identifier)
      end

      def test_semian_can_be_disabled
        resource = trilogy_adapter(
          host: SemianConfig["toxiproxy_upstream_host"],
          port: SemianConfig["mysql_toxiproxy_port"],
          semian: false,
        ).semian_resource

        assert_instance_of(Semian::UnprotectedResource, resource)
      end

      def test_connection_errors_open_the_circuit
        @proxy.downstream(:latency, latency: 2200).apply do
          ERROR_THRESHOLD.times do
            assert_raises(ActiveRecord::StatementInvalid) do
              @adapter.execute("SELECT 1;")
            end
          end

          assert_raises(TrilogyAdapter::CircuitOpenError) do
            @adapter.execute("SELECT 1;")
          end
        end
      end

      def test_query_errors_do_not_open_the_circuit
        (ERROR_THRESHOLD).times do
          assert_raises(ActiveRecord::StatementInvalid) do
            @adapter.execute("ERROR!")
          end
        end
        err = assert_raises(ActiveRecord::StatementInvalid) do
          @adapter.execute("ERROR!")
        end
        refute_kind_of(TrilogyAdapter::CircuitOpenError, err)
      end

      private

      def trilogy_adapter(**config_overrides)
        TrilogyAdapter.new(@configuration.merge(config_overrides))
      end
    end
  end
end
