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

      def teardown
        @adapter.disconnect!
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

      def test_read_timeout_error_opens_the_circuit
        ERROR_THRESHOLD.times do
          assert_raises(ActiveRecord::StatementInvalid) do
            @adapter.execute("SELECT sleep(5)")
          end
        end

        assert_raises(TrilogyAdapter::CircuitOpenError) do
          @adapter.execute("SELECT sleep(5)")
        end

        # After TrilogyAdapter::CircuitOpenError check regular queries are working fine.
        result = Timecop.travel(ERROR_TIMEOUT + 1) do
          @adapter.execute("SELECT 1 + 1;")
        end

        assert_equal(2, result.first[0])
      end

      def test_connect_instrumentation
        notified = false
        subscriber = Semian.subscribe do |event, resource, scope, adapter|
          next unless event == :success

          notified = true

          assert_equal(Semian[:trilogy_adapter_testing], resource)
          assert_equal(:connection, scope)
          assert_equal(:trilogy_adapter, adapter)
        end

        @adapter.connect!

        assert(notified, "No notifications have been emitted")
      ensure
        Semian.unsubscribe(subscriber)
      end

      def test_query_instrumentation
        @adapter.connect!

        notified = false
        subscriber = Semian.subscribe do |event, resource, scope, adapter|
          notified = true
          assert_equal(:success, event)
          assert_equal(Semian[:trilogy_adapter_testing], resource)
          assert_equal(:execute, scope)
          assert_equal(:trilogy_adapter, adapter)
        end

        @adapter.execute("SELECT 1;")

        assert(notified, "No notifications has been emitted")
      ensure
        Semian.unsubscribe(subscriber)
      end

      def test_network_errors_are_tagged_with_the_resource_identifier
        @proxy.down do
          error = assert_raises(ActiveRecord::StatementInvalid) do
            @adapter.execute("SELECT 1 + 1;")
          end
          assert_equal(@adapter.semian_identifier, error.semian_identifier)
        end
      end

      def test_other_mysql_errors_are_not_tagged_with_the_resource_identifier
        error = assert_raises(ActiveRecord::StatementInvalid) do
          @adapter.execute("SYNTAX ERROR!")
        end
        assert_nil(error.semian_identifier)
      end

      private

      def trilogy_adapter(**config_overrides)
        TrilogyAdapter.new(@configuration.merge(config_overrides))
      end
    end
  end
end
