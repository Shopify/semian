# frozen_string_literal: true

require "test_helper"
require "trilogy"
require "semian/trilogy"

class TestTrilogy < Minitest::Test
  ERROR_TIMEOUT = 5
  ERROR_THRESHOLD = 1
  SEMIAN_OPTIONS = {
    tickets: 1,
    timeout: 0,
    error_threshold: ERROR_THRESHOLD,
    success_threshold: 2,
    error_timeout: ERROR_TIMEOUT,
  }

  def setup
    @proxy = Toxiproxy[:semian_test_mysql]
    Semian.destroy(:mysql_testing)
  end

  def test_semian_identifier
    client = connect_to_mysql!
    assert_equal(:"mysql_toxiproxy:13306", client.semian_identifier)

    client = connect_to_mysql!(semian_options: { name: "foo" })
    assert_equal(:mysql_foo, client.semian_identifier)

    # I don't think there's any way to test with custom host and port options
    #
    # We actually connect to the MySQL server in #initialize, and this
    # fails unless we're using the configured host / port
    #
    # Commenting out for now

    # client = connect_to_mysql!(host: "127.0.0.1")
    # assert_equal(:"mysql_127.0.0.1:3306", client.semian_identifier)

    # client = connect_to_mysql!(host: "example.com", port: 42)
    # assert_equal(:"mysql_example.com:42", client.semian_identifier)
  end

  def test_semian_can_be_disabled
    resource = Trilogy.new(
      host: SemianConfig["toxiproxy_upstream_host"],
      port: SemianConfig["mysql_toxiproxy_port"],
      semian: false,
    ).semian_resource

    assert_instance_of(Semian::UnprotectedResource, resource)
  end

  def test_connection_errors_opens_the_circuit
    @proxy.downstream(:latency, latency: 2200).apply do
      ERROR_THRESHOLD.times do
        assert_raises(::Errno::ETIMEDOUT) do
          connect_to_mysql!
        end
      end

      assert_raises(::Trilogy::CircuitOpenError) do
        connect_to_mysql!
      end
    end
  end

  def test_query_errors_does_not_open_the_circuit
    client = connect_to_mysql!
    (ERROR_THRESHOLD * 2).times do
      assert_raises(::Trilogy::Error) do
        client.query("ERROR!")
      end
    end
  end

  def test_read_timeout_error_opens_the_circuit
    client = connect_to_mysql!

    ERROR_THRESHOLD.times do
      assert_raises(::Errno::ETIMEDOUT) do
        client.query("SELECT sleep(5)")
      end
    end

    assert_raises(Trilogy::CircuitOpenError) do
      client.query("SELECT sleep(5)")
    end

    # After Trilogy::CircuitOpenError check regular queries are working fine.
    result = Timecop.travel(ERROR_TIMEOUT + 1) do
      # Reconnect because trilogy closed the connection
      client = connect_to_mysql!
      client.query("SELECT 1 + 1;")
    end

    assert_equal(2, result.first[0])
  end

  def test_connect_instrumentation
    notified = false
    subscriber = Semian.subscribe do |event, resource, scope, adapter|
      next unless event == :success

      notified = true
      assert_equal(Semian[:mysql_testing], resource)
      assert_equal(:connection, scope)
      assert_equal(:trilogy, adapter)
    end

    connect_to_mysql!(semian_options: { name: "testing" })

    assert(notified, "No notifications have been emitted")
  ensure
    Semian.unsubscribe(subscriber)
  end

  def test_resource_acquisition_for_connect
    connect_to_mysql!(semian_options: { name: "testing" })

    Semian[:mysql_testing].acquire do
      error = assert_raises(Trilogy::ResourceBusyError) do
        connect_to_mysql!(semian_options: { name: "testing" })
      end
      assert_equal(:mysql_testing, error.semian_identifier)
    end
  end

  def test_network_errors_are_tagged_with_the_resource_identifier
    client = connect_to_mysql!
    @proxy.down do
      error = assert_raises(::Trilogy::Error) do
        client.query("SELECT 1 + 1;")
      end
      assert_equal(client.semian_identifier, error.semian_identifier)
    end
  end

  def test_other_mysql_errors_are_not_tagged_with_the_resource_identifier
    client = connect_to_mysql!

    error = assert_raises(Trilogy::Error) do
      client.query("SYNTAX ERROR!")
    end
    assert_nil(error.semian_identifier)
  end

  def test_resource_timeout_on_connect
    @proxy.downstream(:latency, latency: 500).apply do
      background { connect_to_mysql! }

      assert_raises(Trilogy::ResourceBusyError) do
        connect_to_mysql!
      end
    end
  end

  def test_circuit_breaker_on_connect
    @proxy.down do
      ERROR_THRESHOLD.times do
        assert_raises(Errno::ECONNREFUSED) do
          connect_to_mysql!
        end
      end
    end

    assert_raises(Trilogy::CircuitOpenError) do
      connect_to_mysql!
    end

    Timecop.travel(ERROR_TIMEOUT + 1) do
      connect_to_mysql!
    end
  end

  def test_query_instrumentation
    client = connect_to_mysql!(semian_options: { name: "testing" })

    notified = false
    subscriber = Semian.subscribe do |event, resource, scope, adapter|
      notified = true
      assert_equal(:success, event)
      assert_equal(Semian[:mysql_testing], resource)
      assert_equal(:query, scope)
      assert_equal(:trilogy, adapter)
    end

    client.query("SELECT 1 + 1;")

    assert(notified, "No notifications has been emitted")
  ensure
    Semian.unsubscribe(subscriber)
  end

  def test_resource_acquisition_for_query
    client = connect_to_mysql!(semian_options: { name: "testing" })

    Semian[:mysql_testing].acquire do
      assert_raises(Trilogy::ResourceBusyError) do
        client.query("SELECT 1 + 1;")
      end
    end
  end

  def test_semian_allows_rollback
    client = connect_to_mysql!(semian_options: { name: "testing" })

    client.query("START TRANSACTION;")

    Semian[:mysql_testing].acquire do
      client.query("ROLLBACK;")
    end
  end

  def test_semian_allows_rollback_with_marginalia
    client = connect_to_mysql!(semian_options: { name: "testing" })

    client.query("START TRANSACTION;")

    Semian[:mysql_testing].acquire do
      client.query("/*foo:bar*/ ROLLBACK;")
    end
  end

  def test_semian_allows_commit
    client = connect_to_mysql!(semian_options: { name: "testing" })

    client.query("START TRANSACTION;")

    Semian[:mysql_testing].acquire do
      client.query("COMMIT;")
    end
  end

  def test_query_allowlisted_returns_false_for_binary_sql
    binary_query = File.read(File.expand_path("../../fixtures/binary.sql", __FILE__))
    client = connect_to_mysql!
    refute(client.send(:query_allowlisted?, binary_query))
  end

  def test_semian_allows_rollback_to_safepoint
    client = connect_to_mysql!(semian_options: { name: "testing" })

    client.query("START TRANSACTION;")
    client.query("SAVEPOINT foobar;")

    Semian[:mysql_testing].acquire do
      client.query("ROLLBACK TO foobar;")
    end

    client.query("ROLLBACK;")
  end

  def test_semian_allows_release_savepoint
    client = connect_to_mysql!(semian_options: { name: "testing" })

    client.query("START TRANSACTION;")
    client.query("SAVEPOINT foobar;")

    Semian[:mysql_testing].acquire do
      client.query("RELEASE SAVEPOINT foobar;")
    end

    client.query("ROLLBACK;")
  end

  def test_resource_timeout_on_query
    client = connect_to_mysql!
    client2 = connect_to_mysql!

    @proxy.downstream(:latency, latency: 500).apply do
      background { client2.query("SELECT 1 + 1;") }

      assert_raises(Trilogy::ResourceBusyError) do
        client.query("SELECT 1 + 1;")
      end
    end
  end

  def test_circuit_breaker_on_query
    client = connect_to_mysql!
    client2 = connect_to_mysql!

    @proxy.downstream(:latency, latency: 2200).apply do
      background { client2.query("SELECT 1 + 1;") }

      ERROR_THRESHOLD.times do
        assert_raises(Trilogy::ResourceBusyError) do
          client.query("SELECT 1 + 1;")
        end
      end
    end

    yield_to_background

    assert_raises(Trilogy::CircuitOpenError) do
      client.query("SELECT 1 + 1;")
    end

    Timecop.travel(ERROR_TIMEOUT + 1) do
      assert_equal(2, client.query("SELECT 1 + 1;").to_a.flatten.first)
    end
  end

  def test_unconfigured
    client = Trilogy.new(
      host: SemianConfig["toxiproxy_upstream_host"],
      port: SemianConfig["mysql_toxiproxy_port"],
    )

    assert_equal(2, client.query("SELECT 1 + 1;").to_a.flatten.first)
  end

  def test_ping_on_closed_connection_does_not_break_the_circuit
    skip "Need to be able to ask Trilogy if conn is closed"
    client = connect_to_mysql!
    client.close

    (ERROR_THRESHOLD * 2).times do
      assert_equal(false, client.ping)
    end
  end

  def test_pings_are_circuit_broken
    client = connect_to_mysql!

    @proxy.downstream(:latency, latency: 2200).apply do
      ERROR_THRESHOLD.times do
        assert_raises(Errno::ETIMEDOUT) do
          client.ping
        end
      end

      assert_raises(Trilogy::CircuitOpenError) do
        client.ping
      end
    end
  end

  def test_changes_timeout_when_half_open_and_configured
    client = connect_to_mysql!(half_open_resource_timeout: 1)

    @proxy.downstream(:latency, latency: 3000).apply do
      (ERROR_THRESHOLD * 2).times do
        assert_raises(Trilogy::Error) do
          client.query("SELECT 1 + 1;")
        end
      end
    end

    assert_raises(Trilogy::CircuitOpenError) do
      client.query("SELECT 1 + 1;")
    end

    Timecop.travel(ERROR_TIMEOUT + 1) do
      @proxy.downstream(:latency, latency: 1500).apply do
        assert_raises(Trilogy::Error) do
          client.query("SELECT 1 + 1;")
        end
      end
    end

    Timecop.travel(ERROR_TIMEOUT * 2 + 1) do
      client.query("SELECT 1 + 1;")
      client.query("SELECT 1 + 1;")

      # Timeout has reset to the normal 2 seconds now that Circuit is closed
      @proxy.downstream(:latency, latency: 1500).apply do
        client.query("SELECT 1 + 1;")
      end
    end

    assert_equal(2, client.query_options[:connect_timeout])
    assert_equal(2, client.query_options[:read_timeout])
    assert_equal(2, client.query_options[:write_timeout])
  end

  def test_circuit_open_errors_do_not_trigger_the_circuit_breaker
    @proxy.down do
      3.times do
        assert_raises(Trilogy::Error) do
          connect_to_mysql!
        end
        assert_equal(Trilogy::Error, Semian[:mysql_testing].circuit_breaker.last_error.class)
      end
    end
  end

  private

  def connect_to_mysql!(options = {})
    semian_options = SEMIAN_OPTIONS.merge(options.delete(:semian_options) || {})
    default_options = {
      connect_timeout: 2,
      read_timeout: 2,
      write_timeout: 2,
      reconnect: true,
      host: SemianConfig["toxiproxy_upstream_host"],
      port: SemianConfig["mysql_toxiproxy_port"],
      semian: semian_options,
    }
    Trilogy.new(default_options.merge(options))
  end
end
