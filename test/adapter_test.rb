# frozen_string_literal: true

require "test_helper"

class TestSemianAdapter < Minitest::Test
  def setup
    destroy_all_semian_resources
  end

  def test_adapter_registers_consumer
    assert_empty(Semian.resources)
    assert_empty(Semian.consumers)
    client = Semian::AdapterTestClient.new(quota: 0.5)
    resource = client.semian_resource

    assert_equal(resource, Semian.resources[client.semian_identifier])
    assert_equal(client, Semian.consumers[client.semian_identifier].keys.first)
  end

  def test_unregister
    skip if ENV["SKIP_FLAKY_TESTS"]
    client = Semian::AdapterTestClient.new(quota: 0.5)

    assert_nil(Semian.resources[:testing_unregister])
    resource = Semian.register(
      :testing_unregister,
      tickets: 2,
      error_threshold: 1,
      error_timeout: 1,
      success_threshold: 1,
    )

    assert_equal(Semian.resources[:testing_unregister], resource)

    assert_equal(1, resource.registered_workers)

    without_gc do
      Semian.unregister(:testing_unregister)

      assert_equal(0, resource.registered_workers)

      assert_empty(Semian.resources)
      assert_empty(Semian.consumers)

      # The first call to client.semian_resource after unregistering all resources,
      # should return a *different* (new) resource.
      refute_equal(resource, client.semian_resource)
    end
    assert_nil(Semian.resources[:testing_unregister])
  end

  def test_unregister_all_resources
    client = Semian::AdapterTestClient.new(quota: 0.5)
    resource = client.semian_resource

    assert_equal(resource, Semian.resources[client.semian_identifier])
    assert_equal(client, Semian.consumers[client.semian_identifier].keys.first)

    # need to disable GC to ensure client weak reference is alive for assertion below
    without_gc do
      assert_equal(resource, client.semian_resource)
      Semian.unregister_all_resources

      assert_empty(Semian.resources)
      assert_empty(Semian.consumers)

      # The first call to client.semian_resource after unregistering all resources,
      # should return a *different* (new) resource.
      refute_equal(resource, client.semian_resource)
    end
  end

  def test_consumer_registration_does_not_prevent_gc
    clients = 10.times.map do
      client = Semian::AdapterTestClient.new(quota: 0.5)
      client.semian_resource
      client
    end

    identifier = clients[0].semian_identifier

    assert_equal(10, Semian.consumers[identifier].size)

    clients.clear
    2.times { GC.start }

    assert_operator(Semian.consumers[identifier].size, :<=, 1)
  end

  def test_does_not_memoize_dynamic_options
    dynamic_client = Semian::DynamicAdapterTestClient.new(quota: 0.5)

    refute_nil(dynamic_client.semian_resource)
    assert_equal(4, dynamic_client.raw_semian_options[:success_threshold])
    assert_equal(5, dynamic_client.raw_semian_options[:success_threshold])
    assert_nil(dynamic_client.instance_variable_get("@semian_options"))
  end

  def test_dynamic_adapter_not_registered_as_consumer
    assert_empty(Semian.consumers)

    dynamic_client = Semian::DynamicAdapterTestClient.new(quota: 0.5)
    resource = dynamic_client.semian_resource

    assert_equal(resource, Semian.resources[dynamic_client.semian_identifier])
    assert_empty(Semian.consumers)
  end

  class MyAdapterError < StandardError
    include Semian::AdapterError
  end

  def test_adapter_error_message
    error = MyAdapterError.new("[ServiceClass] Different prefixes")
    error.semian_identifier = :my_service

    assert_equal("[my_service] [ServiceClass] Different prefixes", error.message)

    error = MyAdapterError.new("[my_service] Same Prefix")
    error.semian_identifier = :my_service

    assert_equal("[my_service] Same Prefix", error.message)
  end

  def test_concurrent_consumer_registration
    threads = []
    thread_count = 10
    clients_created = Concurrent::Array.new
    exceptions_caught = Concurrent::AtomicFixnum.new(0)

    thread_count.times do |i|
      threads << Thread.new do
        client = Semian::AdapterTestClient.new(
          quota: 0.5,
          name: "concurrent_test_#{i}",
        )

        # Override the semian_identifier to make each client unique
        client.define_singleton_method(:semian_identifier) do
          "concurrent_test_#{i}".to_sym
        end

        resource = client.semian_resource

        clients_created << {
          client: client,
          resource: resource,
          identifier: client.semian_identifier,
          thread_id: i,
        }
      rescue => e
        exceptions_caught.increment
        puts "Exception in registration thread #{i}: #{e.class}: #{e.message}"
      end
    end

    threads.each(&:join)

    assert_equal(0, exceptions_caught.value, "No exceptions should occur during concurrent registration")
    assert_equal(thread_count, clients_created.size, "All registration clients should be created")

    clients_created.each do |client_data|
      client = client_data[:client]
      identifier = client_data[:identifier]

      assert(Semian.consumers.key?(identifier), "Consumer should be registered for identifier: #{identifier}")

      consumer_map = Semian.consumers[identifier]

      assert_kind_of(ObjectSpace::WeakMap, consumer_map, "Consumer map should be a WeakMap")
      assert(consumer_map.key?(client), "Client should be registered in consumer map")
      assert_equal(client_data[:resource], Semian.resources[identifier], "Resource should match")
    end
  end

  def test_concurrent_resource_unregistration
    threads = []
    thread_count = 10
    unregistrations_performed = Concurrent::Array.new
    exceptions_caught = Concurrent::AtomicFixnum.new(0)

    # Create initial resources to unregister
    initial_resources = []
    thread_count.times do |i|
      Semian.register(
        "initial_resource_#{i}".to_sym,
        tickets: 2,
        error_threshold: 1,
        error_timeout: 1,
        success_threshold: 1,
      )
      initial_resources << "initial_resource_#{i}".to_sym
    end

    threads.each(&:join)

    thread_count.times do |i|
      threads << Thread.new do
        resource_to_unregister = initial_resources[i]
        Semian.unregister(resource_to_unregister)
        unregistrations_performed << {
          identifier: resource_to_unregister,
          thread_id: i,
        }
      rescue => e
        exceptions_caught.increment
        puts "Exception in unregistration thread #{i}: #{e.class}: #{e.message}"
      end
    end

    threads.each(&:join)

    assert_equal(0, exceptions_caught.value, "No exceptions should occur during concurrent unregistration")
    assert_equal(thread_count, unregistrations_performed.size, "All unregistrations should be performed")

    # Verify all resources were unregistered
    unregistrations_performed.each do |unregistration_data|
      identifier = unregistration_data[:identifier]

      assert_nil(Semian.resources[identifier], "Resource #{identifier} should be unregistered")
      refute(Semian.consumers.key?(identifier), "Consumer #{identifier} should be removed")
    end
  end

  def test_instrumentable_subscribers_change
    notifications_received = Concurrent::Array.new

    # Helper method to create subscribers with different names
    create_subscriber = ->(name) do
      ->(event, resource, scope, adapter, *payload) do
        notifications_received << {
          subscriber: name,
          event: event,
          resource: resource,
          scope: scope,
          adapter: adapter,
          payload: payload,
        }
      end
    end

    subscriber1 = create_subscriber.call(:subscriber1)
    subscriber2 = create_subscriber.call(:subscriber2)
    subscriber3 = create_subscriber.call(:subscriber3)

    initial_subscribers_size = Semian.send(:subscribers).size

    # Subscribe multiple subscribers
    id1 = Semian.subscribe(:sub1, &subscriber1)
    id2 = Semian.subscribe(:sub2, &subscriber2)
    id3 = Semian.subscribe(:sub3, &subscriber3)

    assert_equal(initial_subscribers_size + 3, Semian.send(:subscribers).size)
    assert_equal(:sub1, id1)
    assert_equal(:sub2, id2)
    assert_equal(:sub3, id3)

    Semian.notify("test_event", "test_resource", "test_scope", "test_adapter", extra: "payload")

    assert_equal(3, notifications_received.size)

    received_subscribers = notifications_received.map { |n| n[:subscriber] }.sort

    assert_equal([:subscriber1, :subscriber2, :subscriber3], received_subscribers)

    notifications_received.each do |notification|
      assert_equal("test_event", notification[:event])
      assert_equal("test_resource", notification[:resource])
      assert_equal("test_scope", notification[:scope])
      assert_equal("test_adapter", notification[:adapter])
      assert_equal([{ extra: "payload" }], notification[:payload])
    end

    notifications_received.clear

    unsubscribed = Semian.unsubscribe(:sub2)

    assert_equal(subscriber2, unsubscribed)

    assert_equal(initial_subscribers_size + 2, Semian.send(:subscribers).size)

    Semian.notify("test_event2", "test_resource2", "test_scope2", "test_adapter2")

    assert_equal(2, notifications_received.size)

    received_subscribers = notifications_received.map { |n| n[:subscriber] }.sort

    assert_equal([:subscriber1, :subscriber3], received_subscribers)

    threads = []
    thread_exceptions = Concurrent::AtomicFixnum.new(0)

    5.times do |i|
      threads << Thread.new do
        temp_id = Semian.subscribe("temp_#{i}".to_sym) do |*args|
        end

        Semian.unsubscribe(temp_id)
      rescue => e
        thread_exceptions.increment
        puts "Exception in subscriber thread #{i}: #{e.class}: #{e.message}"
      end
    end

    threads.each(&:join)

    assert_equal(0, thread_exceptions.value, "No exceptions should occur during concurrent subscribe/unsubscribe")

    Semian.unsubscribe(:sub1)
    Semian.unsubscribe(:sub3)

    assert_equal(initial_subscribers_size, Semian.send(:subscribers).size)
  end

  def without_gc
    GC.disable
    yield
  ensure
    GC.enable
  end
end
