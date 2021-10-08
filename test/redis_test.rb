# frozen_string_literal: true

require "test_helper"
require "benchmark"

begin
  require "hiredis"
  require "redis/connection/hiredis"
  puts "running tests with hiredis driver"
rescue LoadError
  puts "running test with default redis driver"
end

class TestRedis < Minitest::Test
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
    assert_equal(:redis_foo, new_redis(semian: { name: "foo" })._client.semian_identifier)
    assert_equal(:"redis_#{SemianConfig["toxiproxy_upstream_host"]}:16379/1",
      new_redis(semian: { name: nil })._client.semian_identifier)
    assert_equal(:"redis_example.com:42/1",
      new_redis(host: "example.com", port: 42, semian: { name: nil })._client.semian_identifier)
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
    redis.pipelined do
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

  def test_command_errors_does_not_open_the_circuit
    client = connect_to_redis!
    client.hset("my_hash", "foo", "bar")
    (ERROR_THRESHOLD * 2).times do
      assert_raises(Redis::CommandError) do
        client.get("my_hash")
      end
    end
  end

  def test_command_errors_because_of_oom_do_open_the_circuit
    client = connect_to_redis!

    with_maxmemory(1) do
      ERROR_THRESHOLD.times do
        exception = assert_raises(::Redis::OutOfMemoryError) do
          client.set("foo", "bar")
        end

        assert_equal(:redis_testing, exception.semian_identifier)
      end

      assert_raises(::Redis::CircuitOpenError) do
        client.set("foo", "bla")
      end
    end
  end

  def test_script_errors_because_of_oom_do_open_the_circuit
    client = connect_to_redis!

    with_maxmemory(1) do
      ERROR_THRESHOLD.times do
        exception = assert_raises(::Redis::OutOfMemoryError) do
          client.eval("return redis.call('set', 'foo', 'bar');")
        end

        assert_equal(:redis_testing, exception.semian_identifier)
      end

      assert_raises(::Redis::CircuitOpenError) do
        client.eval("return redis.call('set', 'foo', 'bar');")
      end
    end
  end

  def test_connect_instrumentation
    notified = false
    subscriber = Semian.subscribe do |event, resource, scope, adapter|
      next unless event == :success

      notified = true
      assert_equal(Semian[:redis_testing], resource)
      assert_equal(:connection, scope)
      assert_equal(:redis, adapter)
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
      error = assert_raises(::Redis::TimeoutError) do
        redis = connect_to_redis!
        redis.get("foo")
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
    refute(error.respond_to?(:semian_identifier))
  end

  def test_resource_timeout_on_connect
    @proxy.downstream(:latency, latency: redis_timeout_ms).apply do
      background { connect_to_redis! }

      assert_raises(Redis::ResourceBusyError) do
        connect_to_redis!
      end
    end
  end

  def test_dns_resolution_failures_open_circuit
    ERROR_THRESHOLD.times do
      assert_raises(Redis::ResolveError) do
        connect_to_redis!(host: "thisdoesnotresolve")
      end
    end

    assert_raises(Redis::CircuitOpenError) do
      connect_to_redis!(host: "thisdoesnotresolve")
    end

    Timecop.travel(ERROR_TIMEOUT + 1) do
      connect_to_redis!
    end
  end

  [
    "Temporary failure in name resolution",
    "Can't resolve example.com",
    "name or service not known",
    "Could not resolve hostname example.com: nodename nor servname provided, or not known",
  ].each do |message|
    test_suffix = message.gsub(/\W/, "_").downcase
    define_method(:"test_dns_resolution_failure_#{test_suffix}") do
      Redis::Client.any_instance.expects(:raw_connect).raises(message)

      assert_raises Redis::ResolveError do
        connect_to_redis!(host: "example.com")
      end
    end
  end

  def test_circuit_breaker_on_connect
    @proxy.downstream(:latency, latency: redis_timeout_ms).apply do
      background { connect_to_redis! }

      ERROR_THRESHOLD.times do
        assert_raises(Redis::ResourceBusyError) do
          connect_to_redis!
        end
      end
    end

    yield_to_background

    assert_raises(Redis::CircuitOpenError) do
      connect_to_redis!
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
      assert_equal(:redis, adapter)
    end

    client.get("foo")

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
    Timecop.travel(time_circuit_half_open) do
      assert_redis_timeout_in_delta(expected_timeout: half_open_resource_timeout) do
        client.get("foo")
      end
    end

    time_circuit_closed = time_circuit_half_open + ERROR_TIMEOUT + 1
    Timecop.travel(time_circuit_closed) do
      SUCCESS_THRESHOLD.times { client.get("foo") }

      # Timeout has reset now that the Circuit is closed
      assert_redis_timeout_in_delta(expected_timeout: REDIS_TIMEOUT) do
        client.get("foo")
      end
    end

    assert_equal(REDIS_TIMEOUT, client.instance_variable_get(:@client).options[:timeout])
    assert_equal(REDIS_TIMEOUT, client.instance_variable_get(:@client).options[:connect_timeout])
    assert_equal(REDIS_TIMEOUT, client.instance_variable_get(:@client).options[:read_timeout])
    assert_equal(REDIS_TIMEOUT, client.instance_variable_get(:@client).options[:write_timeout])
    assert_equal(REDIS_TIMEOUT, client.instance_variable_get(:@client).timeout)
  end

  def test_timeout_changes_when_half_open_and_configured_with_writes_and_disconnects
    half_open_resource_timeout = 0.1
    client = connect_to_redis!(half_open_resource_timeout: half_open_resource_timeout)

    Timecop.freeze(0) do
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
    Timecop.travel(time_circuit_half_open) do
      assert_redis_timeout_in_delta(expected_timeout: half_open_resource_timeout) do
        client.set("foo", 1)
      end
    end

    client.close

    time_circuit_closed = time_circuit_half_open + ERROR_TIMEOUT + 1
    Timecop.travel(time_circuit_closed) do
      SUCCESS_THRESHOLD.times { client.set("foo", 1) }

      assert_redis_timeout_in_delta(expected_timeout: REDIS_TIMEOUT) do
        client.set("foo", 1)
      end
    end

    assert_equal(REDIS_TIMEOUT, client.instance_variable_get(:@client).options[:timeout])
    assert_equal(REDIS_TIMEOUT, client.instance_variable_get(:@client).options[:connect_timeout])
    assert_equal(REDIS_TIMEOUT, client.instance_variable_get(:@client).options[:read_timeout])
    assert_equal(REDIS_TIMEOUT, client.instance_variable_get(:@client).options[:write_timeout])
    assert_equal(REDIS_TIMEOUT, client.instance_variable_get(:@client).timeout)
  end

  def test_timeout_doesnt_change_when_half_open_but_not_configured
    client = connect_to_redis!

    Timecop.freeze(0) do
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
    Timecop.travel(time_circuit_half_open) do
      assert_redis_timeout_in_delta(expected_timeout: REDIS_TIMEOUT) do
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

    Timecop.travel(ERROR_TIMEOUT + 1) do
      assert_equal("2", client.get("foo"))
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
    }.merge(options))
  end

  def connect_to_redis!(semian_options = {})
    host = semian_options.delete(:host)
    redis = new_redis(host: host, semian: semian_options)
    redis._client.connect
    redis
  end

  def with_maxmemory(bytes)
    client = connect_to_redis!(name: "maxmemory")

    _, old = client.config("get", "maxmemory")
    begin
      client.config("set", "maxmemory", bytes)
      yield
    ensure
      client.config("set", "maxmemory", old)
    end
  end

  def redis_timeout_ms
    @redis_timeout_ms ||= (REDIS_TIMEOUT * 1000).to_i
  end

  def assert_redis_timeout_in_delta(expected_timeout:, delta: 0.1, &block)
    latency = ((expected_timeout + 2 * delta) * 1000).to_i

    bench = Benchmark.measure do
      assert_raises(Redis::TimeoutError) do
        @proxy.downstream(:latency, latency: latency).apply(&block)
      end
    end
    assert_in_delta(bench.real, expected_timeout, delta)
  end
end
