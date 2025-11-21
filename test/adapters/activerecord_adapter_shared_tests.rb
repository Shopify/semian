# frozen_string_literal: true

require "helpers/background_helper"

module ActiveRecordAdapterSharedTests
  include BackgroundHelper

  ERROR_TIMEOUT = 5
  ERROR_THRESHOLD = 1
  SEMIAN_OPTIONS = {
    name: "testing",
    tickets: 1,
    timeout: 0,
    error_threshold: ERROR_THRESHOLD,
    success_threshold: 2,
    error_timeout: ERROR_TIMEOUT,
  }.freeze

  def setup
    super
    @proxy = toxyproxy_resource
  end

  def teardown
    super
    @adapter.disconnect!
  end

  def test_semian_identifier
    assert_equal(:"#{adapter_identifier_prefix}_testing", @adapter.semian_identifier)

    adapter = adapter_class.new(
      adapter: @configuration[:adapter],
      username: @configuration[:username],
      password: @configuration[:password],
      host: "127.0.0.1",
      semian: { name: nil },
    )

    assert_equal(:"#{adapter_identifier_prefix}_127.0.0.1:#{adapter_default_port}", adapter.semian_identifier)

    adapter = new_adapter(host: "shopify.com", port: 42, semian: { name: nil })

    assert_equal(:"#{adapter_identifier_prefix}_shopify.com:42", adapter.semian_identifier)
  end

  def test_semian_can_be_disabled
    resource = new_adapter(
      host: toxyproxy_host,
      port: toxyproxy_port,
      semian: false,
    ).semian_resource

    assert_instance_of(Semian::UnprotectedResource, resource)
  end

  def test_adapter_does_not_modify_config
    assert(@configuration.key?(:semian))
    adapter_class.new(@configuration)

    assert(@configuration.key?(:semian))
  end

  def test_unconfigured
    adapter = new_adapter(
      host: toxyproxy_host,
      port: toxyproxy_port,
    )

    value = adapter.query_value("SELECT 1 + 1;")

    assert_equal(2, value)
  end

  def test_connection_errors_open_the_circuit
    @proxy.downstream(:latency, latency: 2200).apply do
      ERROR_THRESHOLD.times do
        assert_raises(ActiveRecord::ConnectionNotEstablished) do
          @adapter.execute("SELECT 1;")
        end
      end

      assert_raises(adapter_class::CircuitOpenError) do
        @adapter.execute("SELECT 1;")
      end
    end
  end

  def test_query_errors_do_not_open_the_circuit
    ERROR_THRESHOLD.times do
      assert_raises(ActiveRecord::StatementInvalid) do
        @adapter.execute("ERROR!")
      end
    end
    err = assert_raises(ActiveRecord::StatementInvalid) do
      @adapter.execute("ERROR!")
    end

    refute_kind_of(adapter_class::CircuitOpenError, err)
  end

  def test_connect_instrumentation
    notified = false
    subscriber = Semian.subscribe do |event, resource, scope, adapter|
      next unless event == :success

      notified = true

      assert_equal(adapter_resource, resource)
      assert_equal(:connection, scope)
      assert_equal(adapter_name, adapter)
    end

    # We can't use the public #connect! API here because we'll call
    # active?, which will scope the event to :ping.
    @adapter.send(:connect)

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
      assert_equal(adapter_resource, resource)
      assert_equal(:query, scope)
      assert_equal(adapter_name, adapter)
    end

    @adapter.execute("SELECT 1;")

    assert(notified, "No notifications has been emitted")
  ensure
    Semian.unsubscribe(subscriber)
  end

  def test_active_instrumentation
    @adapter.connect!

    notified = false
    subscriber = Semian.subscribe do |event, resource, scope, adapter|
      notified = true

      assert_equal(:success, event)
      assert_equal(adapter_resource, resource)
      assert_equal(:ping, scope)
      assert_equal(adapter_name, adapter)
    end

    @adapter.active?

    assert(notified, "No notifications has been emitted")
  ensure
    Semian.unsubscribe(subscriber)
  end

  def test_network_errors_are_tagged_with_the_resource_identifier
    @proxy.down do
      error = assert_raises(ActiveRecord::ConnectionNotEstablished) do
        @adapter.execute("SELECT 1 + 1;")
      end

      assert_equal(@adapter.semian_identifier, error.semian_identifier)
    end
  end

  def test_connection_failed_errors_are_tagged_with_the_resource_identifier
    @adapter.send(:raw_connection).close

    error = assert_raises(ActiveRecord::ConnectionFailed, ActiveRecord::ConnectionNotEstablished) do
      @adapter.execute("SELECT 1 + 1;")
    end

    assert_equal(@adapter.semian_identifier, error.semian_identifier)
  end

  def test_other_errors_are_not_tagged_with_the_resource_identifier
    error = assert_raises(ActiveRecord::StatementInvalid) do
      @adapter.execute("SYNTAX ERROR!")
    end

    assert_nil(error.semian_identifier)
  end

  def test_resource_acquisition_for_connect
    @adapter.connect!

    adapter_resource.acquire do
      error = assert_raises(adapter_class::ResourceBusyError) do
        new_adapter.send(:connect) # Avoid going through connect!, which will call #active?
      end

      assert_equal(@adapter.semian_identifier, error.semian_identifier)
    end
  end

  def test_resource_acquisition_for_query
    @adapter.connect!

    adapter_resource.acquire do
      assert_raises(adapter_class::ResourceBusyError) do
        @adapter.execute("SELECT 1;")
      end
    end
  end

  def test_resource_timeout_on_connect
    @proxy.downstream(:latency, latency: 500).apply do
      background do
        assert_raises(adapter_class::CircuitOpenError) { @adapter.connect! }
      end

      assert_raises(adapter_class::ResourceBusyError) do
        new_adapter.send(:connect) # Avoid going through connect!, which will call #active?
      end
    end
  end

  def test_circuit_breaker_on_connect
    @proxy.downstream(:latency, latency: 500).apply do
      background do
        assert_raises(adapter_class::CircuitOpenError) { @adapter.connect! }
      end

      ERROR_THRESHOLD.times do
        assert_raises(adapter_class::ResourceBusyError) do
          new_adapter.send(:connect) # Avoid going through connect!, which will call #active?
        end
      end
    end

    yield_to_background

    time_travel(ERROR_TIMEOUT + 1) do
      new_adapter.connect!
    end
  end

  def test_resource_timeout_on_query
    adapter2 = new_adapter

    @proxy.downstream(:latency, latency: 500).apply do
      background { adapter2.execute("SELECT 1 + 1;") }

      assert_raises(adapter_class::ResourceBusyError) do
        @adapter.query_value("SELECT 1 + 1;")
      end
    end
  end

  def test_circuit_breaker_on_query
    @proxy.downstream(:latency, latency: 2200).apply do
      background { new_adapter.execute("SELECT 1 + 1;") }

      ERROR_THRESHOLD.times do
        assert_raises(adapter_class::ResourceBusyError) do
          @adapter.query_value("SELECT 1 + 1;")
        end
      end
    end

    yield_to_background

    assert_raises(adapter_class::CircuitOpenError) do
      @adapter.execute("SELECT 1 + 1;")
    end

    time_travel(ERROR_TIMEOUT + 1) do
      value = @adapter.query_value("SELECT 1 + 1;")

      assert_equal(2, value)
    end
  end

  def test_semian_allows_rollback
    @adapter.execute("START TRANSACTION;")

    adapter_resource.acquire do
      @adapter.execute("ROLLBACK")
    end
  end

  def test_semian_allows_rollback_with_marginalia
    @adapter.execute("START TRANSACTION;")

    adapter_resource.acquire do
      @adapter.execute("/*foo:bar*/ ROLLBACK")
    end
  end

  def test_semian_allows_commit
    @adapter.execute("START TRANSACTION;")

    adapter_resource.acquire do
      @adapter.execute("COMMIT")
    end
  end

  def test_query_allowlisted_returns_false_for_binary_sql
    binary_query = File.read(File.expand_path("../../fixtures/binary.sql", __FILE__))

    refute(adapter_class.query_allowlisted?(binary_query))
  end

  def test_semian_allows_release_savepoint
    @adapter.execute("START TRANSACTION;")
    @adapter.execute("SAVEPOINT active_record_2;")

    adapter_resource.acquire do
      @adapter.execute("RELEASE SAVEPOINT active_record_2")
    end

    @adapter.execute("ROLLBACK;")
  end

  def test_semian_allows_rollback_to_savepoint
    @adapter.execute("START TRANSACTION;")
    @adapter.execute("SAVEPOINT active_record_1;")

    adapter_resource.acquire do
      @adapter.execute("ROLLBACK TO SAVEPOINT active_record_1")
    end

    @adapter.execute("ROLLBACK")
  end

  def test_circuit_open_errors_do_not_trigger_the_circuit_breaker
    @proxy.down do
      ERROR_THRESHOLD.times do
        assert_raises(ActiveRecord::ConnectionNotEstablished) do
          @adapter.execute("SELECT 1;")
        end
      end

      assert_raises(adapter_class::CircuitOpenError) do
        @adapter.execute("SELECT 1;")
      end
      error = adapter_resource.circuit_breaker.last_error

      assert_instance_of(ActiveRecord::ConnectionNotEstablished, error)
    end
  end

  private

  def adapter_class
    raise NotImplementedError
  end

  def new_adapter(**config_overrides)
    adapter_class.new(@configuration.merge(config_overrides))
  end

  def adapter_name
    raise NotImplementedError
  end

  def adapter_default_port
    raise NotImplementedError
  end

  def adapter_identifier_prefix
    raise NotImplementedError
  end

  def adapter_resource
    raise NotImplementedError
  end

  def toxyproxy_host
    SemianConfig["toxiproxy_upstream_host"]
  end

  def toxyproxy_port
    raise NotImplementedError
  end

  def toxyproxy_resource
    raise NotImplementedError
  end

  def sleep_query(seconds)
    raise NotImplementedError
  end
end
