# frozen_string_literal: true

require "test_helper"
require "redis"
require "hiredis"
require "hiredis-client"
require "benchmark"
require "semian/redis"

module RedisTests
  include BackgroundHelper

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
  }.freeze

  def setup
    super
    @proxy = Toxiproxy[:semian_test_redis]
    Semian.destroy(:redis_testing)
  end

  def test_semian_identifier
    assert_equal(:redis_foo, new_redis(semian: { name: "foo" })._client.semian_identifier)
    assert_equal(
      :"redis_#{SemianConfig["toxiproxy_upstream_host"]}:16379/1",
      new_redis(semian: { name: nil })._client.semian_identifier,
    )
    assert_equal(
      :"redis_shopify.com:42/1",
      new_redis(host: "shopify.com", port: 42, semian: { name: nil })._client.semian_identifier,
    )
  end

  def test_client_alias
    redis = connect_to_redis!

    assert_equal(redis._client.semian_resource, redis.semian_resource)
    assert_equal(redis._client.semian_identifier, redis.semian_identifier)
  end

  def test_semian_can_be_disabled
    resource = Redis.new(semian: false)._client.semian_resource

    assert_instance_of(Semian::UnprotectedResource, resource)
  end

  def test_semian_resource_in_pipeline
    redis = connect_to_redis!

    redis.pipelined do |_pipeline|
      assert_instance_of(Semian::ProtectedResource, redis.semian_resource)
    end
  end

  def test_connection_errors_open_the_circuit
    client = connect_to_redis!

    @proxy.downstream(:latency, latency: 600).apply do
      ERROR_THRESHOLD.times do
        assert_raises(::Redis::TimeoutError) do
          client.get("foo")
        end
      end

      assert_raises(::Redis::CircuitOpenError) do
        client.get("foo")
      end
    end
  end

  def test_connection_reset_does_not_open_the_circuit
    client = connect_to_redis!

    @proxy.downstream(:reset_peer).apply do
      ERROR_THRESHOLD.times do
        assert_raises(::Redis::BaseConnectionError) do
          client.get("foo")
        end
      end

      assert_raises(::Redis::BaseConnectionError) do
        client.get("foo")
      end
    end
  end

  def test_command_errors_does_not_open_the_circuit
    client = connect_to_redis!
    client.hset("my_hash", "foo", "bar")

    (ERROR_THRESHOLD * 2).times do
      assert_raises(Redis::CommandError) do
        client.get("my_hash")
      end
    end
  end

  def test_command_errors_because_of_oom_open_the_circuit
    # By default, OOM errors open the circuit (backward compatible behavior)
    client = connect_to_redis!

    with_maxmemory(1) do
      ERROR_THRESHOLD.times do
        exception = assert_raises(::Redis::OutOfMemoryError) do
          client.set("foo", "bar")
        end

        assert_equal(:redis_testing, exception.semian_identifier)
      end

      # Circuit should be open now
      assert_raises(::Redis::CircuitOpenError) do
        client.set("foo", "bla")
      end
    end
  end

  def test_script_errors_because_of_oom_open_the_circuit
    # By default, OOM errors open the circuit (backward compatible behavior)
    client = connect_to_redis!

    with_maxmemory(1) do
      ERROR_THRESHOLD.times do
        exception = assert_raises(::Redis::OutOfMemoryError) do
          client.eval("return redis.call('set', 'foo', 'bar');")
        end

        assert_equal(:redis_testing, exception.semian_identifier)
      end

      # Circuit should be open now
      assert_raises(::Redis::CircuitOpenError) do
        client.eval("return redis.call('set', 'foo', 'bar');")
      end
    end
  end

  def test_command_errors_because_of_oom_do_not_open_the_circuit_when_disabled
    # When open_circuit_on_oom is false, OOM errors should NOT open the circuit
    # This allows reads/dequeues to continue, helping Redis recover from OOM
    Semian.destroy(:redis_testing_oom)
    client = connect_to_redis!(semian: { name: :testing_oom, open_circuit_on_oom: false })

    with_maxmemory(1) do
      (ERROR_THRESHOLD + 1).times do
        exception = assert_raises(::Redis::OutOfMemoryError) do
          client.set("foo", "bar")
        end

        assert_equal(:redis_testing_oom, exception.semian_identifier)
      end

      # Circuit should NOT be open - we should still get OOM errors, not CircuitOpenError
      assert_raises(::Redis::OutOfMemoryError) do
        client.set("foo", "bla")
      end
    end
  ensure
    Semian.destroy(:redis_testing_oom)
  end

  def test_connect_instrumentation
    notified = false
    subscriber = Semian.subscribe do |event, resource, scope, adapter|
      next unless event == :success
      next if scope == :query

      notified = true

      assert_equal(Semian[:redis_testing], resource)
      assert_equal(:connection, scope)
      if ::Redis::VERSION >= "5"
        assert_equal(:redis_client, adapter)
      else
        assert_equal(:redis, adapter)
      end
    end

    connect_to_redis!

    assert(notified, "No notifications has been emitted")
  ensure
    Semian.unsubscribe(subscriber)
  end

  def test_resource_acquisition_for_connect
    connect_to_redis!

    Semian[:redis_testing].acquire do
      error = assert_raises(Redis::ResourceBusyError) do
        connect_to_redis!
      end

      assert_equal(:redis_testing, error.semian_identifier)
    end
  end

  def test_redis_connection_errors_are_tagged_with_the_resource_identifier
    @proxy.downstream(:latency, latency: 600).apply do
      error = assert_raises(::Redis::BaseConnectionError) do
        connect_to_redis!
      end

      assert_equal(:redis_testing, error.semian_identifier)
    end
  end

  def test_other_redis_errors_are_not_tagged_with_the_resource_identifier
    client = connect_to_redis!
    client.set("foo", "bar")
    error = assert_raises(::Redis::CommandError) do
      client.hget("foo", "bar")
    end

    refute_respond_to(error, :semian_identifier)
  end

  def test_resource_timeout_on_connect
    @proxy.downstream(:latency, latency: redis_timeout_ms).apply do
      background do
        connect_to_redis!
      rescue Redis::CircuitOpenError
        nil
      end

      assert_raises(Redis::ResourceBusyError) do
        connect_to_redis!
      end
    end
  end

  def test_dns_resolution_failures_open_circuit
    ERROR_THRESHOLD.times do
      assert_resolve_error do
        connect_to_redis!(host: "thisdoesnotresolve")
      end
    end

    assert_raises(Redis::CircuitOpenError) do
      connect_to_redis!(host: "thisdoesnotresolve")
    end

    time_travel(ERROR_TIMEOUT + 1) do
      connect_to_redis!
    end
  end

  [
    "Temporary failure in name resolution",
    "Can't resolve shopify.com",
    "name or service not known",
    "Could not resolve hostname shopify.com: nodename nor servname provided, or not known",
  ].each do |message|
    test_suffix = message.gsub(/\W/, "_").downcase
    define_method(:"test_dns_resolution_failure_#{test_suffix}") do
      if ::Redis::VERSION >= "5"
        Redis::Client.any_instance.expects(:connect).raises(RedisClient::CannotConnectError.new(message))
      else
        Redis::Client.any_instance.expects(:raw_connect).raises(message)
      end

      assert_resolve_error do
        connect_to_redis!(host: "shopify.com")
      end
    end
  end

  def test_circuit_breaker_on_connect
    background_redis = connect_to_redis!(timeout: 5, reconnect_attempts: 0)
    @proxy.downstream(:latency, latency: 3_000).apply do
      background { background_redis.ping }

      ERROR_THRESHOLD.times do
        assert_raises(Redis::ResourceBusyError) do
          connect_to_redis!(reconnect_attempts: 0)
        end
      end
    end

    yield_to_background

    assert_raises(Redis::CircuitOpenError) do
      connect_to_redis!
    end

    time_travel(ERROR_TIMEOUT + 1) do
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
      if ::Redis::VERSION >= "5"
        assert_equal(:redis_client, adapter)
      else
        assert_equal(:redis, adapter)
      end
    end

    client.get("foo")

    assert(notified, "No notifications has been emitted")
  ensure
    Semian.unsubscribe(subscriber)
  end

  def test_timeout_changes_when_half_open_and_configured_with_reads
    half_open_resource_timeout = 0.1
    client = connect_to_redis!(semian: { half_open_resource_timeout: half_open_resource_timeout })

    time_travel(0) do
      @proxy.downstream(:latency, latency: redis_timeout_ms + 200).apply do
        ERROR_THRESHOLD.times do
          assert_raises(::Redis::TimeoutError) do
            client.get("foo")
          end
        end
      end

      assert_raises(::Redis::CircuitOpenError) do
        client.get("foo")
      end
    end

    time_circuit_half_open = ERROR_TIMEOUT + 1
    assert_redis_timeout_in_delta(expected_timeout: half_open_resource_timeout) do
      time_travel(time_circuit_half_open) do
        client.get("foo")
      end
    end

    time_circuit_closed = time_circuit_half_open + ERROR_TIMEOUT + 1
    time_travel(time_circuit_closed) do
      SUCCESS_THRESHOLD.times { client.get("foo") }
    end

    # Timeout has reset now that the Circuit is closed
    assert_redis_timeout_in_delta(expected_timeout: REDIS_TIMEOUT) do
      client.get("foo")
    end

    assert_default_timeouts(client)
  end

  def test_timeout_changes_when_half_open_and_configured_with_writes_and_disconnects
    half_open_resource_timeout = 0.1
    client = connect_to_redis!(semian: { half_open_resource_timeout: half_open_resource_timeout })

    time_travel(0) do
      @proxy.downstream(:latency, latency: redis_timeout_ms + 200).apply do
        ERROR_THRESHOLD.times do
          assert_raises(::Redis::TimeoutError) do
            client.set("foo", 1)
          end
        end
      end

      assert_raises(::Redis::CircuitOpenError) do
        client.set("foo", 1)
      end
    end

    client.close

    time_circuit_half_open = ERROR_TIMEOUT + 1
    assert_redis_timeout_in_delta(expected_timeout: half_open_resource_timeout) do
      time_travel(time_circuit_half_open) do
        client.set("foo", 1)
      end
    end

    client.close

    time_circuit_closed = time_circuit_half_open + ERROR_TIMEOUT + 1
    time_travel(time_circuit_closed) do
      SUCCESS_THRESHOLD.times { client.set("foo", 1) }
    end

    assert_redis_timeout_in_delta(expected_timeout: REDIS_TIMEOUT) do
      client.set("foo", 1)
    end

    assert_default_timeouts(client)
  end

  def test_timeout_doesnt_change_when_half_open_but_not_configured
    client = connect_to_redis!

    time_travel(0) do
      @proxy.downstream(:latency, latency: redis_timeout_ms + 200).apply do
        ERROR_THRESHOLD.times do
          assert_raises(::Redis::TimeoutError) do
            client.get("foo")
          end
        end
      end

      assert_raises(::Redis::CircuitOpenError) do
        client.get("foo")
      end
    end

    time_circuit_half_open = ERROR_TIMEOUT + 1
    assert_redis_timeout_in_delta(expected_timeout: REDIS_TIMEOUT) do
      time_travel(time_circuit_half_open) do
        client.get("foo")
      end
    end
  end

  def test_resource_acquisition_for_query
    client = connect_to_redis!

    Semian[:redis_testing].acquire do
      assert_raises(Redis::ResourceBusyError) do
        client.get("foo")
      end
    end
  end

  def test_resource_timeout_on_query
    client = connect_to_redis!
    client2 = connect_to_redis!

    @proxy.downstream(:latency, latency: redis_timeout_ms).apply do
      background { client2.get("foo") }

      assert_raises(Redis::ResourceBusyError) do
        client.get("foo")
      end
    end
  end

  def test_circuit_breaker_on_query
    client = connect_to_redis!
    client2 = connect_to_redis!

    client.set("foo", 2)

    @proxy.downstream(:latency, latency: 1000).apply do
      background { client2.get("foo") }

      ERROR_THRESHOLD.times do
        assert_raises(Redis::ResourceBusyError) do
          client.get("foo")
        end
      end
    end

    yield_to_background

    assert_raises(Redis::CircuitOpenError) do
      client.get("foo")
    end

    time_travel(ERROR_TIMEOUT + 1) do
      assert_equal("2", client.get("foo"))
    end
  end

  def test_readonly_errors_does_not_open_the_circuit
    client = connect_to_redis!

    with_readonly_mode(client) do
      ERROR_THRESHOLD.times do
        assert_raises(::Redis::ReadOnlyError, ::Redis::CommandError) do
          client.set("foo", "bar")
        end
      end

      error = assert_raises(::Redis::ReadOnlyError, ::Redis::CommandError) do
        client.set("foo", "bar")
      end

      assert_match("READONLY You can't write against a read only replica.", error.message)
    end
  end

  private

  def new_redis(options = {})
    options[:host] = SemianConfig["toxiproxy_upstream_host"] if options[:host].nil?
    semian_options = SEMIAN_OPTIONS.merge(options.delete(:semian) || {})
    Redis.new({
      port: SemianConfig["redis_toxiproxy_port"],
      reconnect_attempts: 0,
      db: 1,
      timeout: REDIS_TIMEOUT,
      semian: semian_options,
      driver: redis_driver,
    }.merge(options))
  end

  if Redis::VERSION >= "5"
    def connect_to_redis!(options = {})
      redis = new_redis(**options)
      redis.ping
      redis
    end
  else
    def connect_to_redis!(options = {})
      redis = new_redis(**options)
      redis._client.connect
      redis
    end
  end

  def with_maxmemory(bytes)
    client = connect_to_redis!(semian: { name: "maxmemory" })

    result = client.config("get", "maxmemory")
    # Redis v5 returns a hash like {"maxmemory"=>"0"} instead of an array
    old = result.is_a?(Hash) ? result["maxmemory"] : result[1]
    begin
      client.config("set", "maxmemory", bytes)
      yield
    ensure
      client.config("set", "maxmemory", old)
    end
  end

  def with_readonly_mode(client)
    client.replicaof("localhost", "6379")
    yield
  ensure
    client.replicaof("NO", "ONE")
  end

  def redis_timeout_ms
    @redis_timeout_ms ||= (REDIS_TIMEOUT * 1000).to_i
  end

  def assert_redis_timeout_in_delta(expected_timeout:, delta: 0.1, &block)
    latency = ((expected_timeout + 2 * delta) * 1000).to_i

    bench = Benchmark.measure do
      assert_raises(Redis::BaseConnectionError) do
        @proxy.downstream(:latency, latency: latency).apply(&block)
      end
    end

    assert_in_delta(bench.real, expected_timeout, delta)
  end

  if ::Redis::VERSION >= "5"
    def assert_default_timeouts(client)
      assert_equal(REDIS_TIMEOUT, client._client.timeout)
      assert_equal(REDIS_TIMEOUT, client._client.connect_timeout)
      assert_equal(REDIS_TIMEOUT, client._client.read_timeout)
      assert_equal(REDIS_TIMEOUT, client._client.write_timeout)
    end

    def assert_resolve_error(&block)
      assert_raises(Redis::CannotConnectError, &block)
    end
  else
    def assert_default_timeouts(client)
      assert_equal(REDIS_TIMEOUT, client.instance_variable_get(:@client).options[:timeout])
      assert_equal(REDIS_TIMEOUT, client.instance_variable_get(:@client).options[:connect_timeout])
      assert_equal(REDIS_TIMEOUT, client.instance_variable_get(:@client).options[:read_timeout])
      assert_equal(REDIS_TIMEOUT, client.instance_variable_get(:@client).options[:write_timeout])
    end

    def assert_resolve_error(&block)
      assert_raises(Redis::ResolveError, &block)
    end
  end
end

class TestRedis < Minitest::Test
  include RedisTests

  private

  def redis_driver
    :ruby
  end
end

class TestHiredis < Minitest::Test
  include RedisTests

  private

  def redis_driver
    :hiredis
  end
end
