# frozen_string_literal: true

require "test_helper"
require "redis-client"
require "hiredis-client"
require "semian/redis_client"
require "benchmark"

module RedisClientTests
  REDIS_TIMEOUT = 0.5
  ERROR_TIMEOUT = 5
  ERROR_THRESHOLD = 1
  SUCCESS_THRESHOLD = 2
  SEMIAN_OPTIONS = {
    name: :testing,
    tickets: 1,
    timeout: 0,
    error_threshold: ERROR_THRESHOLD,
    success_threshold: SUCCESS_THRESHOLD,
    error_timeout: ERROR_TIMEOUT,
  }

  attr_writer :threads

  def setup
    @proxy = Toxiproxy[:semian_test_redis]
    Semian.destroy(:redis_testing)
  end

  def test_semian_identifier
    assert_equal(:redis_foo, new_config(semian: { name: "foo" }).semian_identifier)
    assert_equal(:"redis_#{SemianConfig["toxiproxy_upstream_host"]}:16379/1",
      new_config(semian: { name: nil }).semian_identifier)
    assert_equal(:"redis_example.com:42/1",
      new_config(host: "example.com", port: 42, semian: { name: nil }).semian_identifier)

    config = new_config(semian: { name: "foo" })

    assert_equal(:redis_foo, config.new_client.semian_identifier)
    assert_equal(:redis_foo, config.new_pool.semian_identifier)
  end

  def test_config_alias
    config = new_config
    client = config.new_client
    client2 = config.new_client

    assert_equal(client.semian_resource, client2.semian_resource)
    assert_equal(client.semian_identifier, client2.semian_identifier)
  end

  def test_semian_can_be_disabled
    resource = RedisClient.new(semian: false).semian_resource

    assert_instance_of(Semian::UnprotectedResource, resource)
  end

  def test_connection_errors_open_the_circuit
    client = connect_to_redis!

    @proxy.downstream(:latency, latency: 600).apply do
      ERROR_THRESHOLD.times do
        assert_raises(RedisClient::ReadTimeoutError) do
          client.call("GET", "foo")
        end
      end

      assert_raises(RedisClient::CircuitOpenError) do
        client.call("GET", "foo")
      end
    end
  end

  def test_connection_reset_does_not_open_the_circuit
    client = connect_to_redis!

    @proxy.downstream(:reset_peer).apply do
      ERROR_THRESHOLD.times do
        assert_raises(RedisClient::ConnectionError) do
          client.call("GET", "foo")
        end
      end

      assert_raises(RedisClient::ConnectionError) do
        client.call("GET", "foo")
      end
    end
  end

  def test_command_errors_does_not_open_the_circuit
    client = connect_to_redis!
    client.call("HSET", "my_hash", "foo", "bar")
    (ERROR_THRESHOLD * 2).times do
      assert_raises(RedisClient::CommandError) do
        client.call("GET", "my_hash")
      end
    end
  end

  def test_connect_instrumentation
    notified = false
    subscriber = Semian.subscribe do |event, resource, scope, adapter|
      next unless event == :success
      next if scope == :query

      notified = true

      assert_equal(Semian[:redis_testing], resource)
      assert_equal(:connection, scope)
      assert_equal(:redis_client, adapter)
    end

    connect_to_redis!

    assert(notified, "No notifications has been emitted")
  ensure
    Semian.unsubscribe(subscriber)
  end

  def test_resource_acquisition_for_connect
    connect_to_redis!

    Semian[:redis_testing].acquire do
      error = assert_raises(RedisClient::ResourceBusyError) do
        connect_to_redis!
      end

      assert_equal(:redis_testing, error.semian_identifier)
    end
  end

  def test_redis_connection_errors_are_tagged_with_the_resource_identifier
    @proxy.downstream(:latency, latency: 600).apply do
      error = assert_raises(RedisClient::ConnectionError) do
        connect_to_redis!
      end

      assert_equal(:redis_testing, error.semian_identifier)
    end
  end

  def test_other_redis_errors_are_not_tagged_with_the_resource_identifier
    client = connect_to_redis!
    client.call("set", "foo", "bar")
    error = assert_raises(RedisClient::CommandError) do
      client.call("hget", "foo", "bar")
    end

    refute_respond_to(error, :semian_identifier)
  end

  def test_resource_timeout_on_connect
    @proxy.downstream(:latency, latency: redis_timeout_ms).apply do
      background { connect_to_redis! }

      assert_raises(RedisClient::ResourceBusyError) do
        connect_to_redis!
      end
    end
  end

  def test_dns_resolution_failures_open_circuit
    ERROR_THRESHOLD.times do
      assert_raises(RedisClient::ConnectionError) do
        connect_to_redis!(host: "thisdoesnotresolve")
      end
    end

    assert_raises(RedisClient::CircuitOpenError) do
      connect_to_redis!(host: "thisdoesnotresolve")
    end

    Timecop.travel(ERROR_TIMEOUT + 1) do
      connect_to_redis!
    end
  end

  def test_query_instrumentation
    client = connect_to_redis!

    notified = false
    subscriber = Semian.subscribe do |event, resource, scope, adapter|
      notified = true

      assert_equal(:success, event)
      assert_equal(Semian[:redis_testing], resource)
      assert_equal(:query, scope)
      assert_equal(:redis_client, adapter)
    end

    client.call("get", "foo")

    assert(notified, "No notifications has been emitted")
  ensure
    Semian.unsubscribe(subscriber)
  end

  def test_timeout_changes_when_half_open_and_configured_with_reads
    half_open_resource_timeout = 0.1
    client = connect_to_redis!(half_open_resource_timeout: half_open_resource_timeout)

    Timecop.freeze(0) do
      @proxy.downstream(:latency, latency: redis_timeout_ms + 200).apply do
        ERROR_THRESHOLD.times do
          assert_raises(RedisClient::TimeoutError) do
            client.call("get", "foo")
          end
        end
      end

      assert_raises(RedisClient::CircuitOpenError) do
        client.call("get", "foo")
      end
    end

    time_circuit_half_open = ERROR_TIMEOUT + 1
    Timecop.travel(time_circuit_half_open) do
      assert_redis_timeout_in_delta(expected_timeout: half_open_resource_timeout) do
        client.call("get", "foo")
      end
    end

    time_circuit_closed = time_circuit_half_open + ERROR_TIMEOUT + 1
    Timecop.travel(time_circuit_closed) do
      SUCCESS_THRESHOLD.times { client.call("get", "foo") }

      # Timeout has reset now that the Circuit is closed
      assert_redis_timeout_in_delta(expected_timeout: REDIS_TIMEOUT) do
        client.call("get", "foo")
      end
    end

    assert_equal(REDIS_TIMEOUT, client.connect_timeout)
    assert_equal(REDIS_TIMEOUT, client.read_timeout)
    assert_equal(REDIS_TIMEOUT, client.write_timeout)
  end

  def test_timeout_changes_when_half_open_and_configured_with_writes_and_disconnects
    half_open_resource_timeout = 0.1
    client = connect_to_redis!(half_open_resource_timeout: half_open_resource_timeout)

    Timecop.freeze(0) do
      @proxy.downstream(:latency, latency: redis_timeout_ms + 200).apply do
        ERROR_THRESHOLD.times do
          assert_raises(RedisClient::TimeoutError) do
            client.call("set", "foo", 1)
          end
        end
      end

      assert_raises(RedisClient::CircuitOpenError) do
        client.call("set", "foo", 1)
      end
    end

    client.close

    time_circuit_half_open = ERROR_TIMEOUT + 1
    Timecop.travel(time_circuit_half_open) do
      assert_redis_timeout_in_delta(expected_timeout: half_open_resource_timeout) do
        client.call("set", "foo", 1)
      end
    end

    client.close

    time_circuit_closed = time_circuit_half_open + ERROR_TIMEOUT + 1
    Timecop.travel(time_circuit_closed) do
      SUCCESS_THRESHOLD.times { client.call("set", "foo", 1) }

      assert_redis_timeout_in_delta(expected_timeout: REDIS_TIMEOUT) do
        client.call("set", "foo", 1)
      end
    end

    assert_equal(REDIS_TIMEOUT, client.connect_timeout)
    assert_equal(REDIS_TIMEOUT, client.read_timeout)
    assert_equal(REDIS_TIMEOUT, client.write_timeout)
  end

  def test_timeout_doesnt_change_when_half_open_but_not_configured
    client = connect_to_redis!

    Timecop.freeze(0) do
      @proxy.downstream(:latency, latency: redis_timeout_ms + 200).apply do
        ERROR_THRESHOLD.times do
          assert_raises(RedisClient::TimeoutError) do
            client.call("get", "foo")
          end
        end
      end

      assert_raises(RedisClient::CircuitOpenError) do
        client.call("get", "foo")
      end
    end

    time_circuit_half_open = ERROR_TIMEOUT + 1
    Timecop.travel(time_circuit_half_open) do
      assert_redis_timeout_in_delta(expected_timeout: REDIS_TIMEOUT) do
        client.call("get", "foo")
      end
    end
  end

  def test_resource_acquisition_for_query
    client = connect_to_redis!

    Semian[:redis_testing].acquire do
      assert_raises(RedisClient::ResourceBusyError) do
        client.call("get", "foo")
      end
    end
  end

  def test_resource_timeout_on_query
    client = connect_to_redis!
    client2 = connect_to_redis!

    @proxy.downstream(:latency, latency: redis_timeout_ms).apply do
      background { client2.call("get", "foo") }

      assert_raises(RedisClient::ResourceBusyError) do
        client.call("get", "foo")
      end
    end
  end

  def test_circuit_breaker_on_query
    client = connect_to_redis!
    client2 = connect_to_redis!

    client.call("set", "foo", 2)

    @proxy.downstream(:latency, latency: 1000).apply do
      background { client2.call("get", "foo") }

      ERROR_THRESHOLD.times do
        assert_raises(RedisClient::ResourceBusyError) do
          client.call("get", "foo")
        end
      end
    end

    yield_to_background

    assert_raises(RedisClient::CircuitOpenError) do
      client.call("get", "foo")
    end

    Timecop.travel(ERROR_TIMEOUT + 1) do
      assert_equal("2", client.call("get", "foo"))
    end
  end

  private

  def new_client(**options)
    new_config(**options).new_client
  end

  def new_config(**options)
    options[:host] = SemianConfig["toxiproxy_upstream_host"] if options[:host].nil?
    semian_options = SEMIAN_OPTIONS.merge(options.delete(:semian) || {})
    RedisClient.config(**{
      port: SemianConfig["redis_toxiproxy_port"],
      reconnect_attempts: 0,
      db: 1,
      timeout: REDIS_TIMEOUT,
      semian: semian_options,
      driver: redis_driver,
    }.merge(options))
  end

  def connect_to_redis!(semian_options = {})
    host = semian_options.delete(:host)
    redis = new_client(host: host, semian: semian_options)
    redis.call("PING")
    redis
  end

  def redis_timeout_ms
    @redis_timeout_ms ||= (REDIS_TIMEOUT * 1000).to_i
  end

  def assert_redis_timeout_in_delta(expected_timeout:, delta: 0.1, &block)
    latency = ((expected_timeout + 2 * delta) * 1000).to_i

    bench = Benchmark.measure do
      assert_raises(RedisClient::ConnectionError) do
        @proxy.downstream(:latency, latency: latency).apply(&block)
      end
    end

    assert_in_delta(bench.real, expected_timeout, delta)
  end
end

class TestRedisClient < Minitest::Test
  include RedisClientTests

  private

  def redis_driver
    :ruby
  end
end

class TestHiredisClient < Minitest::Test
  include RedisClientTests

  private

  def redis_driver
    :hiredis
  end
end
