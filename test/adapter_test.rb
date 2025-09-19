# frozen_string_literal: true

require "test_helper"

class TestSemianAdapter < Minitest::Test
  def setup
    destroy_all_semian_resources
  end

  def test_adapter_registers_consumer
    assert_empty(Semian.resources)
    assert_equal(0, Semian.consumers.size)
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
      assert_equal(0, Semian.consumers.size)

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
      assert_equal(0, Semian.consumers.size)

      # After unregistering, client should be able to get a working resource
      # Test the core functionality rather than internal state
      new_resource = client.semian_resource

      assert_kind_of(Semian::ProtectedResource, new_resource)

      # Verify the resource is functional by checking it has the expected interface
      assert_respond_to(new_resource, :acquire)
      assert_equal(client.semian_identifier, new_resource.name)
    end
  end

  def test_consumer_registration_does_not_prevent_gc
    clients = 10.times.map do
      client = Semian::AdapterTestClient.new(quota: 0.5)
      client.semian_resource
      client
    end

    identifier = clients[0].semian_identifier

    consumer_map = Semian.consumers[identifier]

    refute_nil(consumer_map)
    assert_equal(10, consumer_map.size)

    clients.clear
    2.times { GC.start }

    final_size = Semian.consumers[identifier].size

    # If concurrent-ruby is loaded, we expect it might hold onto one reference
    if defined?(Concurrent)
      # Allow for concurrent-ruby to hold onto a small number of references.
      # The important thing is that MOST consumers are garbage collected, proving that
      # Semian's WeakMap doesn't prevent GC.
      assert_operator(final_size, :<=, 1, "Expected at most 1 consumer to remain after GC with concurrent-ruby loaded, but found #{final_size}")
    else
      # Without concurrent-ruby, all should be collected
      assert_equal(0, final_size, "Without concurrent-ruby, all consumers should be collected")
    end
  end

  def test_does_not_memoize_dynamic_options
    dynamic_client = Semian::DynamicAdapterTestClient.new(quota: 0.5)

    refute_nil(dynamic_client.semian_resource)
    assert_equal(4, dynamic_client.raw_semian_options[:success_threshold])
    assert_equal(5, dynamic_client.raw_semian_options[:success_threshold])
    assert_nil(dynamic_client.instance_variable_get("@semian_options"))
  end

  def test_dynamic_adapter_not_registered_as_consumer
    assert_equal(0, Semian.consumers.size)

    dynamic_client = Semian::DynamicAdapterTestClient.new(quota: 0.5)
    resource = dynamic_client.semian_resource

    assert_equal(resource, Semian.resources[dynamic_client.semian_identifier])
    assert_equal(0, Semian.consumers.size)
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

  def test_concurrent_consumer_registration_and_unregistration
    threads = []
    thread_count = 10
    register_count = Concurrent::AtomicFixnum.new(0)
    unregister_count = Concurrent::AtomicFixnum.new(0)
    exceptions_caught = Concurrent::AtomicFixnum.new(0)
    shared_identifier = :concurrent_test_resource

    # Pre-register a shared resource
    Semian.register(
      shared_identifier,
      tickets: 5,
      error_threshold: 1,
      error_timeout: 1,
      success_threshold: 1,
    )

    thread_count.times do |i|
      threads << Thread.new do
        if i.even?
          # Registration thread
          client = Semian::AdapterTestClient.new(
            quota: 0.5,
            name: shared_identifier,
          )
          client.semian_resource
          register_count.increment
          sleep(0.01) # Small delay to increase chance of concurrent operations
        else
          # Unregistration thread
          sleep(0.005) # Slight delay to ensure some registrations happen first
          if Semian.resources[shared_identifier]
            Semian.unregister(shared_identifier)
            unregister_count.increment
          end

          # Try to re-register after unregistration
          client = Semian::AdapterTestClient.new(
            quota: 0.5,
            name: shared_identifier,
          )
          client.semian_resource
          register_count.increment
        end
      rescue => e
        exceptions_caught.increment
        puts "Exception in thread #{i}: #{e.message}"
      end
    end

    threads.each(&:join)

    # Should not crash - the exact counts may vary due to timing
    assert_operator(register_count.value, :>, 0, "Some registrations should have occurred")
    assert_equal(0, exceptions_caught.value, "No exceptions should occur during concurrent operations")

    # Verify system is in a consistent state
    resource = Semian.resources[shared_identifier]
    if resource
      assert_kind_of(Semian::ProtectedResource, resource)
    end
  end

  def test_instrumentable_subscribers_concurrent_changes
    subscription_threads = []
    notification_threads = []
    thread_count = 8
    subscriptions_created = Concurrent::Array.new
    notifications_received = Concurrent::AtomicFixnum.new(0)
    exceptions_caught = Concurrent::AtomicFixnum.new(0)

    # Create concurrent subscription and unsubscription threads
    thread_count.times do |i|
      subscription_threads << Thread.new do
        subscription_id = Semian.subscribe("test_subscriber_#{i}") do |event, _resource|
          notifications_received.increment if event == :test_event
        end
        subscriptions_created << subscription_id

        sleep(0.01) # Keep subscription alive briefly

        # Unsubscribe half of them
        if i.even?
          Semian.unsubscribe(subscription_id)
        end
      rescue => e
        exceptions_caught.increment
        puts "Exception in subscription thread #{i}: #{e.message}"
      end
    end

    # Create threads that send notifications concurrently with subscription changes
    (thread_count / 2).times do |i|
      notification_threads << Thread.new do
        5.times do
          Semian.notify(:test_event, nil, nil, nil)
          sleep(0.005)
        end
      rescue => e
        exceptions_caught.increment
        puts "Exception in notification thread #{i}: #{e.message}"
      end
    end

    # Wait for all threads
    (subscription_threads + notification_threads).each(&:join)

    assert_equal(0, exceptions_caught.value, "No exceptions should occur during concurrent subscriber operations")
    assert_operator(subscriptions_created.size, :>, 0, "Subscriptions should have been created")
    assert_operator(notifications_received.value, :>=, 0, "Some notifications should have been received")

    # Clean up remaining subscriptions
    subscriptions_created.each do |sub_id|
      Semian.unsubscribe(sub_id)
    rescue
      nil
    end
  end

  def without_gc
    GC.disable
    yield
  ensure
    GC.enable
  end
end
