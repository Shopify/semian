require 'test/unit'
require 'semian/mysql2'
require 'toxiproxy'
require 'timecop'

class TestMysql2 < Test::Unit::TestCase
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

  def teardown
    threads.each { |t| t.kill }
    @threads = []
  end

  def test_semian_identifier
    assert_equal :mysql_foo, FakeMysql.new(semian: {name: 'foo'}).semian_identifier
    assert_equal :'mysql_localhost:3306', FakeMysql.new.semian_identifier
    assert_equal :'mysql_127.0.0.1:3306', FakeMysql.new(host: '127.0.0.1').semian_identifier
    assert_equal :'mysql_example.com:42', FakeMysql.new(host: 'example.com', port: 42).semian_identifier
  end

  def test_resource_acquisition_for_connect
    client = connect_to_mysql!

    Semian[:mysql_testing].acquire do
      assert_raises Mysql2::ResourceOccupiedError do
        connect_to_mysql!
      end
    end
  end

  def test_resource_timeout_on_connect
    @proxy.downstream(:latency, latency: 500).apply do
      background { connect_to_mysql! }

      assert_raises Mysql2::ResourceOccupiedError do
        connect_to_mysql!
      end
    end
  end

  def test_circuit_breaker_on_connect
    @proxy.downstream(:latency, latency: 500).apply do
      background { connect_to_mysql! }

      ERROR_THRESHOLD.times do
        assert_raises Mysql2::ResourceOccupiedError do
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

  def test_resource_acquisition_for_query
    client = connect_to_mysql!

    Semian[:mysql_testing].acquire do
      assert_raises Mysql2::ResourceOccupiedError do
        client.query('SELECT 1 + 1;')
      end
    end
  end

  def test_resource_timeout_on_query
    client = connect_to_mysql!
    client2 = connect_to_mysql!

    @proxy.downstream(:latency, latency: 500).apply do
      background { client2.query('SELECT 1 + 1;') }

      assert_raises Mysql2::ResourceOccupiedError do
        client.query('SELECT 1 + 1;')
      end
    end
  end

  def test_circuit_breaker_on_query
    client = connect_to_mysql!
    client2 = connect_to_mysql!

    @proxy.downstream(:latency, latency: 1000).apply do
      background { client2.query('SELECT 1 + 1;') }

      ERROR_THRESHOLD.times do
        assert_raises Mysql2::ResourceOccupiedError do
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

  private

  def background(&block)
    thread = Thread.new(&block)
    threads << thread
    thread.join(0.1)
    thread
  end

  def threads
    @threads ||= []
  end

  def yield_to_background
    threads.each(&:join)
  end

  def connect_to_mysql!(semian_options = {})
    Mysql2::Client.new(host: '127.0.0.1', port: '43306', semian: SEMIAN_OPTIONS.merge(semian_options))
  end

  class FakeMysql < Mysql2::Client
    private
    def connect(*)
    end
  end
end
