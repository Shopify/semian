require 'test_helper'

class TestSemianAdapter < Minitest::Test
  def setup
    Semian.unregister_all_resources
    # Consumers registered in other test files must be cleared
    Semian.reset!
  end

  def teardown
    Semian.unregister_all_resources
  end

  def test_adapter_registers_consumer
    assert_empty(Semian.resources)
    assert_empty(Semian.consumers)
    client = Semian::AdapterTestClient.new(quota: 0.5)
    resource = client.semian_resource
    assert_equal(resource, Semian.resources[client.semian_identifier])
    assert_equal(client, Semian.consumers[client.semian_identifier].first)
  end

  def test_unregister
    skip if ENV["SKIP_FLAKY_TESTS"]
    client = Semian::AdapterTestClient.new(quota: 0.5)
    assert_nil(Semian.resources[:testing])
    resource = Semian.register(:testing, tickets: 2, error_threshold: 0, error_timeout: 0, success_threshold: 0)
    assert_equal(Semian.resources[:testing], resource)

    assert_equal 1, resource.registered_workers

    without_gc do
      Semian.unregister(:testing)
      assert_equal 0, resource.registered_workers

      assert_empty(Semian.resources)
      assert_empty(Semian.consumers)

      # The first call to client.semian_resource after unregistering all resources,
      # should return a *different* (new) resource.
      refute_equal(resource, client.semian_resource)
    end
    assert_nil(Semian.resources[:testing])
  end

  def test_unregister_all_resources
    client = Semian::AdapterTestClient.new(quota: 0.5)
    resource = client.semian_resource
    assert_equal(resource, Semian.resources[client.semian_identifier])
    assert_equal(client, Semian.consumers[client.semian_identifier].first)

    # need to disable GC to ensure client weak reference is alive for assertion below
    without_gc do
      assert_equal(resource, client.semian_resource)
      Semian.unregister_all_resources

      assert Semian.resources.empty?
      assert_empty(Semian.consumers)

      # The first call to client.semian_resource after unregistering all resources,
      # should return a *different* (new) resource.
      refute_equal(resource, client.semian_resource)
    end
  end

  def test_consumer_registration_does_not_prevent_gc
    client = Semian::AdapterTestClient.new(quota: 0.5)
    client.semian_resource
    identifier = client.semian_identifier

    # Release the only strong reference to the client object
    # so that it will be cleared on the forced GC run below
    client = nil
    weak_ref = Semian.consumers[identifier].first
    assert_equal(true, weak_ref.weakref_alive?)

    GC.start(full_mark: true, immediate_sweep: true)

    assert_nil weak_ref.weakref_alive?

    assert_raises WeakRef::RefError do
      weak_ref.any_method_call
    end
  end

  def without_gc
    GC.disable
    yield
  ensure
    GC.enable
  end
end
