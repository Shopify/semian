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
    thread_count = 5
    clients_created = Concurrent::Array.new
    exceptions_caught = Concurrent::AtomicFixnum.new(0)

    thread_count.times do |i|
      threads << Thread.new do
        client = Semian::AdapterTestClient.new(
          quota: 0.5,
          name: "thread_test_#{i}",
        )

        resource = client.semian_resource

        clients_created << {
          client: client,
          resource: resource,
          identifier: client.semian_identifier,
          thread_id: i,
        }
      rescue
        exceptions_caught.increment
      end
    end

    threads.each(&:join)

    assert_equal(0, exceptions_caught.value, "No exceptions should occur during concurrent consumer registration")

    assert_equal(thread_count, clients_created.size, "All clients should be registered")

    clients_created.each do |client_data|
      client = client_data[:client]
      identifier = client_data[:identifier]

      assert(Semian.consumers.key?(identifier), "Consumer should be registered for identifier: #{identifier}")

      consumer_map = Semian.consumers[identifier]

      assert_kind_of(ObjectSpace::WeakMap, consumer_map, "Consumer map should be a WeakMap")
      assert(consumer_map.key?(client), "Client should be registered in consumer map")
    end

    clients_created.each do |client_data|
      resource = client_data[:resource]
      identifier = client_data[:identifier]

      assert_equal(resource, Semian.resources[identifier], "Resource should match registered resource")
    end
  end

  def without_gc
    GC.disable
    yield
  ensure
    GC.enable
  end
end
