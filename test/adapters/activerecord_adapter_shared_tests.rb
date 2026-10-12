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
        assert_raises(*connection_failed_error_classes) do
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
      error = assert_raises(*connection_failed_error_classes) do
        @adapter.execute("SELECT 1 + 1;")
      end

      assert_equal(@adapter.semian_identifier, error.semian_identifier)
    end
  end

  def test_connection_failed_errors_are_tagged_with_the_resource_identifier
    @adapter.send(:raw_connection).close

    error = assert_raises(*connection_failed_error_classes) do
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
        assert_raises(*connection_failed_error_classes) do
          @adapter.execute("SELECT 1;")
        end
      end

      assert_raises(adapter_class::CircuitOpenError) do
        @adapter.execute("SELECT 1;")
      end
      error = adapter_resource.circuit_breaker.last_error

      assert_includes(connection_failed_error_classes, error.class)
    end
  end

  {
    circuit_open: [Semian::OpenCircuitError, :CircuitOpenError],
    resource_busy: [Semian::TimeoutError, :ResourceBusyError],
  }.each do |rejection, (error_class, adapter_error)|
    define_method("test_#{rejection}_is_not_a_retryable_connection_error") do
      error = adapter_class.const_get(adapter_error).new(@adapter.semian_identifier, "access rejected")

      assert_kind_of(ActiveRecord::ConnectionNotEstablished, error)
      refute(@adapter.send(:retryable_connection_error?, error))
    end

    define_method("test_#{rejection}_does_not_retry_reconnect") do
      reject_semian_acquisition(error_class)
      @adapter.expects(:backoff).never

      assert_raises(adapter_class.const_get(adapter_error)) { @adapter.reconnect! }
    end

    define_method("test_#{rejection}_verify_preserves_existing_connection") do
      reject_semian_acquisition(error_class)
      connection = mock("existing connection")
      connection.expects(:reset).never
      connection.expects(:close).never
      @adapter.instance_variable_set(:@raw_connection, connection)

      assert_raises(adapter_class.const_get(adapter_error)) { @adapter.verify! }
      assert_same(connection, @adapter.instance_variable_get(:@raw_connection))
    ensure
      @adapter.instance_variable_set(:@raw_connection, nil)
    end

    define_method("test_#{rejection}_reconnect_preserves_existing_connection") do
      reject_semian_acquisition(error_class)
      connection = mock("existing connection")
      connection.expects(:reset).never
      connection.expects(:close).never
      @adapter.instance_variable_set(:@raw_connection, connection)

      assert_raises(adapter_class.const_get(adapter_error)) { @adapter.reconnect! }
      assert_same(connection, @adapter.instance_variable_get(:@raw_connection))
    ensure
      @adapter.instance_variable_set(:@raw_connection, nil)
    end

    define_method("test_#{rejection}_active_returns_false") do
      reject_semian_acquisition(error_class)

      refute_predicate(@adapter, :active?)
    end

    [false, true].each do |allow_retry|
      define_method("test_#{rejection}_query_does_not_retry_with_allow_retry_#{allow_retry}") do
        reject_semian_acquisition(error_class)
        @adapter.expects(:reconnect!).never
        @adapter.expects(:backoff).never

        assert_raises(adapter_class.const_get(adapter_error)) do
          @adapter.execute("SELECT 1", allow_retry: allow_retry)
        end
      end
    end

    if ActiveRecord.version >= Gem::Version.new("8.2.a")
      define_method("test_#{rejection}_async_query_completes_without_another_acquisition") do
        reject_semian_acquisition(error_class)
        pool = mock("connection pool")
        pool.stubs(:with_connection).yields(@adapter)
        @adapter.stubs(:pool).returns(pool)
        @adapter.stubs(:async_enabled?).returns(true)
        @adapter.stubs(:sql_notifications?).returns(false)
        session = ActiveRecord::AsynchronousQueriesTracker::Session.new
        ActiveRecord::Base.stubs(:asynchronous_queries_session).returns(session)
        intent = ActiveRecord::ConnectionAdapters::QueryIntent.new(
          adapter: @adapter,
          processed_sql: "SELECT 1",
          allow_async: true,
          allow_retry: true,
          materialize_transactions: false,
        )
        intent.retry_budget = @adapter.send(:build_retry_budget, allow_retry: true, reconnectable: true)
        pool.expects(:schedule_query).with(intent)
        intent.execute!

        # Run the background path to completion before observing the result.
        Thread.new { intent.execute_or_skip }.value
        error = intent.error

        assert_instance_of(adapter_class.const_get(adapter_error), error)
        assert(intent.raw_result_available?)
        refute_predicate(intent, :pending?)
        2.times do
          assert_same(error, assert_raises(adapter_class.const_get(adapter_error)) { intent.raw_result })
        end
      ensure
        session&.finalize
      end
    end
  end

  def test_driver_connection_errors_still_retry_reconnect
    @adapter.expects(:reconnect).twice.raises(ActiveRecord::ConnectionFailed)
    @adapter.expects(:backoff).with(1).once

    assert_raises(ActiveRecord::ConnectionFailed) { @adapter.reconnect! }
  end

  [:verify!, :reconnect!].each do |operation|
    define_method("test_connection_recovers_after_rejected_#{operation}") do
      @adapter.connect!
      connection = @adapter.instance_variable_get(:@raw_connection)
      resource = @adapter.semian_resource
      resource.mark_failed(ActiveRecord::ConnectionFailed.new("database unavailable"))

      assert_raises(adapter_class::CircuitOpenError) { @adapter.public_send(operation) }
      assert_same(connection, @adapter.instance_variable_get(:@raw_connection))

      resource.reset
      @adapter.public_send(operation)

      assert_equal(2, @adapter.query_value("SELECT 1 + 1"))
    end
  end

  def test_verify_rejects_an_open_circuit_once
    @adapter = new_adapter(semian: SEMIAN_OPTIONS.merge(bulkhead: false, error_timeout: 3600))
    resource = @adapter.semian_resource
    cause = ActiveRecord::ConnectionFailed.new("database unavailable")
    resource.mark_failed(cause)
    rejections = 0
    subscriber = Semian.subscribe do |event, notified_resource|
      rejections += 1 if event == :circuit_open && notified_resource == resource
    end

    error = assert_raises(adapter_class::CircuitOpenError) { @adapter.verify! }

    assert_same(cause, error.cause)
    assert(resource.open?)
    assert_equal(1, rejections)
  ensure
    Semian.unsubscribe(subscriber)
  end

  def test_verify_acquires_once_for_a_healthy_connection
    @adapter = new_adapter(semian: SEMIAN_OPTIONS.merge(bulkhead: false))
    @adapter.semian_resource.expects(:acquire).once.yields.returns(true)
    connection = mock("healthy connection")
    if adapter_name == :postgresql_adapter
      connection.stubs(:finished?).returns(false)
      connection.stubs(:status).returns(PG::CONNECTION_OK)
    end
    connection.stubs(:query).with(";")
    connection.stubs(:closed?).returns(false)
    connection.stubs(:ping)
    @adapter.instance_variable_set(:@raw_connection, connection)

    @adapter.verify!

    assert_same(connection, @adapter.instance_variable_get(:@raw_connection))
  ensure
    @adapter.instance_variable_set(:@raw_connection, nil)
  end

  private

  def reject_semian_acquisition(error_class)
    @adapter = new_adapter(semian: SEMIAN_OPTIONS.merge(bulkhead: false))
    @adapter.pool.stubs(:shard).returns(:default)
    @adapter.pool.stubs(:role).returns(:writing)
    @adapter.semian_resource.expects(:acquire).once.raises(error_class)
  end

  def adapter_class
    raise NotImplementedError
  end

  def new_adapter(**config_overrides)
    adapter_class.new(@configuration.merge(config_overrides))
  end

  def connection_failed_error_classes
    [ActiveRecord::ConnectionFailed, ActiveRecord::ConnectionNotEstablished]
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
