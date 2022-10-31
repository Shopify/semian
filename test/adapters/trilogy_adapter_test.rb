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

      def test_unconfigured
        adapter = trilogy_adapter(
          host: SemianConfig["toxiproxy_upstream_host"],
          port: SemianConfig["mysql_toxiproxy_port"],
        )

        assert_equal(2, adapter.execute("SELECT 1 + 1;").to_a.flatten.first)
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

      def test_resource_acquisition_for_connect
        @adapter.connect!

        Semian[:trilogy_adapter_testing].acquire do
          error = assert_raises(TrilogyAdapter::ResourceBusyError) do
            trilogy_adapter.connect!
          end
          assert_equal(:trilogy_adapter_testing, error.semian_identifier)
        end
      end

      def test_resource_acquisition_for_query
        @adapter.connect!

        Semian[:trilogy_adapter_testing].acquire do
          assert_raises(TrilogyAdapter::ResourceBusyError) do
            @adapter.execute("SELECT 1;")
          end
        end
      end

      def test_resource_timeout_on_connect
        @proxy.downstream(:latency, latency: 500).apply do
          background { @adapter.connect! }

          assert_raises(TrilogyAdapter::ResourceBusyError) do
            trilogy_adapter.connect!
          end
        end
      end

      def test_circuit_breaker_on_connect
        @proxy.downstream(:latency, latency: 500).apply do
          background { @adapter.connect! }

          ERROR_THRESHOLD.times do
            assert_raises(TrilogyAdapter::ResourceBusyError) do
              trilogy_adapter.connect!
            end
          end
        end

        yield_to_background

        assert_raises(TrilogyAdapter::CircuitOpenError) do
          trilogy_adapter.connect!
        end

        Timecop.travel(ERROR_TIMEOUT + 1) do
          trilogy_adapter.connect!
        end
      end

      def test_resource_timeout_on_query
        adapter2 = trilogy_adapter

        @proxy.downstream(:latency, latency: 500).apply do
          background { adapter2.execute("SELECT 1 + 1;") }

          assert_raises(TrilogyAdapter::ResourceBusyError) do
            @adapter.query("SELECT 1 + 1;")
          end
        end
      end

      def test_circuit_breaker_on_query
        adapter2 = trilogy_adapter

        @proxy.downstream(:latency, latency: 2200).apply do
          background { trilogy_adapter.execute("SELECT 1 + 1;") }

          ERROR_THRESHOLD.times do
            assert_raises(TrilogyAdapter::ResourceBusyError) do
              @adapter.query("SELECT 1 + 1;")
            end
          end
        end

        yield_to_background

        assert_raises(TrilogyAdapter::CircuitOpenError) do
          @adapter.execute("SELECT 1 + 1;")
        end

        Timecop.travel(ERROR_TIMEOUT + 1) do
          assert_equal(2, @adapter.execute("SELECT 1 + 1;").to_a.flatten.first)
        end
      end

      def test_semian_allows_rollback
        @adapter.execute("START TRANSACTION;")

        Semian[:trilogy_adapter_testing].acquire do
          @adapter.execute("ROLLBACK;")
        end
      end

      def test_semian_allows_rollback_with_marginalia
        @adapter.execute("START TRANSACTION;")

        Semian[:trilogy_adapter_testing].acquire do
          @adapter.execute("/*foo:bar*/ ROLLBACK;")
        end
      end

      def test_semian_allows_commit
        @adapter.execute("START TRANSACTION;")

        Semian[:trilogy_adapter_testing].acquire do
          @adapter.execute("COMMIT;")
        end
      end

      def test_query_allowlisted_returns_false_for_binary_sql
        binary_query = File.read(File.expand_path("../../fixtures/binary.sql", __FILE__))
        refute(@adapter.send(:query_allowlisted?, binary_query))
      end

      def test_semian_allows_rollback_to_safepoint
        @adapter.execute("START TRANSACTION;")
        @adapter.execute("SAVEPOINT foobar;")

        Semian[:trilogy_adapter_testing].acquire do
          @adapter.execute("ROLLBACK TO foobar;")
        end

        @adapter.execute("ROLLBACK;")
      end

      def test_semian_allows_release_savepoint
        @adapter.execute("START TRANSACTION;")
        @adapter.execute("SAVEPOINT foobar;")

        Semian[:trilogy_adapter_testing].acquire do
          @adapter.execute("RELEASE SAVEPOINT foobar;")
        end

        @adapter.execute("ROLLBACK;")
      end

      def test_changes_timeout_when_half_open_and_configured
        adapter = trilogy_adapter(semian: SEMIAN_OPTIONS.merge(half_open_resource_timeout: 1))

        @proxy.downstream(:latency, latency: 3000).apply do
          (ERROR_THRESHOLD * 2).times do
            assert_raises(ActiveRecord::StatementInvalid) do
              adapter.execute("SELECT 1 + 1;")
            end
          end
        end

        assert_raises(TrilogyAdapter::CircuitOpenError) do
          adapter.execute("SELECT 1 + 1;")
        end

        Timecop.travel(ERROR_TIMEOUT + 1) do
          @proxy.downstream(:latency, latency: 1500).apply do
            assert_raises(ActiveRecord::StatementInvalid) do
              adapter.execute("SELECT 1 + 1;")
            end
          end
        end

        Timecop.travel(ERROR_TIMEOUT * 2 + 1) do
          adapter.execute("SELECT 1 + 1;")
          adapter.execute("SELECT 1 + 1;")

          # Timeout has reset to the normal 2 seconds now that Circuit is closed
          @proxy.downstream(:latency, latency: 1500).apply do
            adapter.execute("SELECT 1 + 1;")
          end
        end

        raw_connection = adapter.send(:connection)
        assert_equal(2, raw_connection.read_timeout)
        assert_equal(2, raw_connection.write_timeout)
      end

      private

      def trilogy_adapter(**config_overrides)
        TrilogyAdapter.new(@configuration.merge(config_overrides))
      end
    end
  end
end
