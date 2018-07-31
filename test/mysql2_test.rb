require 'test_helper'

class TestMysql2 < Minitest::Test
  ERROR_TIMEOUT = 5
  ERROR_THRESHOLD = 1
  SEMIAN_OPTIONS = {
    name: :testing,
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
    assert_equal :mysql_foo, FakeMysql.new(semian: {name: 'foo'}).semian_identifier
    assert_equal :'mysql_localhost:3306', FakeMysql.new.semian_identifier
    assert_equal :'mysql_127.0.0.1:3306', FakeMysql.new(host: '127.0.0.1').semian_identifier
    assert_equal :'mysql_example.com:42', FakeMysql.new(host: 'example.com', port: 42).semian_identifier
  end

  def test_semian_can_be_disabled
    resource = Mysql2::Client.new(
      host: SemianConfig['toxiproxy_upstream_host'],
      port: SemianConfig['mysql_toxiproxy_port'],
      semian: false).semian_resource

    assert_instance_of Semian::UnprotectedResource, resource
  end

  def test_connection_errors_open_the_circuit
    @proxy.downstream(:latency, latency: 2200).apply do
      ERROR_THRESHOLD.times do
        assert_raises ::Mysql2::Error do
          connect_to_mysql!
        end
      end

      assert_raises ::Mysql2::CircuitOpenError do
        connect_to_mysql!
      end
    end
  end

  def test_query_errors_does_not_open_the_circuit
    client = connect_to_mysql!
    (ERROR_THRESHOLD * 2).times do
      assert_raises ::Mysql2::Error do
        client.query('ERROR!')
      end
    end
  end

  def test_connect_instrumentation
    notified = false
    subscriber = Semian.subscribe do |event, resource, scope, adapter|
      notified = true
      assert_equal :success, event
      assert_equal Semian[:mysql_testing], resource
      assert_equal :connection, scope
      assert_equal :mysql, adapter
    end

    connect_to_mysql!

    assert notified, 'No notifications has been emitted'
  ensure
    Semian.unsubscribe(subscriber)
  end

  def test_resource_acquisition_for_connect
    connect_to_mysql!

    Semian[:mysql_testing].acquire do
      error = assert_raises Mysql2::ResourceBusyError do
        connect_to_mysql!
      end
      assert_equal :mysql_testing, error.semian_identifier
    end
  end

  def test_network_errors_are_tagged_with_the_resource_identifier
    client = connect_to_mysql!
    @proxy.down do
      error = assert_raises ::Mysql2::Error do
        client.query('SELECT 1 + 1;')
      end
      assert_equal client.semian_identifier, error.semian_identifier
    end
  end

  def test_other_mysql_errors_are_not_tagged_with_the_resource_identifier
    client = connect_to_mysql!

    error = assert_raises Mysql2::Error do
      client.query('SYNTAX ERROR!')
    end
    assert_nil error.semian_identifier
  end

  def test_resource_timeout_on_connect
    @proxy.downstream(:latency, latency: 500).apply do
      background { connect_to_mysql! }

      assert_raises Mysql2::ResourceBusyError do
        connect_to_mysql!
      end
    end
  end

  def test_circuit_breaker_on_connect
    @proxy.downstream(:latency, latency: 500).apply do
      background { connect_to_mysql! }

      ERROR_THRESHOLD.times do
        assert_raises Mysql2::ResourceBusyError do
          connect_to_mysql!
        end
      end
    end

    yield_to_background

    assert_raises Mysql2::CircuitOpenError do
      connect_to_mysql!
    end

    Timecop.travel(ERROR_TIMEOUT + 1) do
      connect_to_mysql!
    end
  end

  def test_query_instrumentation
    client = connect_to_mysql!

    notified = false
    subscriber = Semian.subscribe do |event, resource, scope, adapter|
      notified = true
      assert_equal :success, event
      assert_equal Semian[:mysql_testing], resource
      assert_equal :query, scope
      assert_equal :mysql, adapter
    end

    client.query('SELECT 1 + 1;')

    assert notified, 'No notifications has been emitted'
  ensure
    Semian.unsubscribe(subscriber)
  end

  def test_resource_acquisition_for_query
    client = connect_to_mysql!

    Semian[:mysql_testing].acquire do
      assert_raises Mysql2::ResourceBusyError do
        client.query('SELECT 1 + 1;')
      end
    end
  end

  def test_semian_allows_rollback
    client = connect_to_mysql!

    client.query('START TRANSACTION;')

    Semian[:mysql_testing].acquire do
      client.query('ROLLBACK;')
    end
  end

  def test_semian_allows_commit
    client = connect_to_mysql!

    client.query('START TRANSACTION;')

    Semian[:mysql_testing].acquire do
      client.query('COMMIT;')
    end
  end

  def test_query_whitelisted_returns_false_for_binary_sql
    binary_query = File.read(File.expand_path('../fixtures/binary.sql', __FILE__))
    client = connect_to_mysql!
    refute client.send(:query_whitelisted?, binary_query)
  end

  def test_semian_allows_rollback_to_safepoint
    client = connect_to_mysql!

    client.query('START TRANSACTION;')
    client.query('SAVEPOINT foobar;')

    Semian[:mysql_testing].acquire do
      client.query('ROLLBACK TO foobar;')
    end

    client.query('ROLLBACK;')
  end

  def test_semian_allows_release_savepoint
    client = connect_to_mysql!

    client.query('START TRANSACTION;')
    client.query('SAVEPOINT foobar;')

    Semian[:mysql_testing].acquire do
      client.query('RELEASE SAVEPOINT foobar;')
    end

    client.query('ROLLBACK;')
  end

  def test_resource_timeout_on_query
    client = connect_to_mysql!
    client2 = connect_to_mysql!

    @proxy.downstream(:latency, latency: 500).apply do
      background { client2.query('SELECT 1 + 1;') }

      assert_raises Mysql2::ResourceBusyError do
        client.query('SELECT 1 + 1;')
      end
    end
  end

  def test_circuit_breaker_on_query
    client = connect_to_mysql!
    client2 = connect_to_mysql!

    @proxy.downstream(:latency, latency: 2200).apply do
      background { client2.query('SELECT 1 + 1;') }

      ERROR_THRESHOLD.times do
        assert_raises Mysql2::ResourceBusyError do
          client.query('SELECT 1 + 1;')
        end
      end
    end

    yield_to_background

    assert_raises Mysql2::CircuitOpenError do
      client.query('SELECT 1 + 1;')
    end

    Timecop.travel(ERROR_TIMEOUT + 1) do
      assert_equal 2, client.query('SELECT 1 + 1 as sum;').to_a.first['sum']
    end
  end

  def test_unconfigured
    client = Mysql2::Client.new(
      host: SemianConfig['toxiproxy_upstream_host'],
      port: SemianConfig['mysql_toxiproxy_port'],
    )

    assert_equal 2, client.query('SELECT 1 + 1 as sum;').to_a.first['sum']
  end

  def test_pings_are_circuit_broken
    client = connect_to_mysql!

    def client.raw_ping
      @real_pings ||= 0
      @real_pings += 1
      super
    end

    @proxy.downstream(:latency, latency: 2200).apply do
      ERROR_THRESHOLD.times do
        client.ping
      end

      assert_equal false, client.ping
    end

    assert_equal ERROR_THRESHOLD, client.instance_variable_get(:@real_pings)
  end

  def test_changes_timeout_when_half_open_and_configured
    client = connect_to_mysql!(half_open_resource_timeout: 1)

    @proxy.downstream(:latency, latency: 3000).apply do
      (ERROR_THRESHOLD * 2).times do
        assert_raises Mysql2::Error do
          client.query('SELECT 1 + 1;')
        end
      end
    end

    assert_raises Mysql2::CircuitOpenError do
      client.query('SELECT 1 + 1;')
    end

    Timecop.travel(ERROR_TIMEOUT + 1) do
      @proxy.downstream(:latency, latency: 1500).apply do
        assert_raises Mysql2::Error do
          client.query('SELECT 1 + 1;')
        end
      end
    end

    Timecop.travel(ERROR_TIMEOUT * 2 + 1) do
      client.query('SELECT 1 + 1;')
      client.query('SELECT 1 + 1;')

      # Timeout has reset to the normal 2 seconds now that Circuit is closed
      @proxy.downstream(:latency, latency: 1500).apply do
        client.query('SELECT 1 + 1;')
      end
    end

    assert_equal 2, client.query_options[:connect_timeout]
    assert_equal 2, client.query_options[:read_timeout]
    assert_equal 2, client.query_options[:write_timeout]
  end

  private

  def connect_to_mysql!(semian_options = {})
    Mysql2::Client.new(
      connect_timeout: 2,
      read_timeout: 2,
      write_timeout: 2,
      reconnect: true,
      host: SemianConfig['toxiproxy_upstream_host'],
      port: SemianConfig['mysql_toxiproxy_port'],
      semian: SEMIAN_OPTIONS.merge(semian_options),
    )
  end

  class FakeMysql < Mysql2::Client
    private

    def connect(*)
    end
  end
end
