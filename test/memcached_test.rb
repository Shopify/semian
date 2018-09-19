require 'test_helper'
require 'semian/memcached'

class MemcachedTest < Minitest::Test
  def setup
    Semian.destroy(:memcached_testing)
  end

  def test_bulkheads_tickets_are_working
    semian_options = SEMIAN_OPTIONS.merge(
      tickets: 2,
    )

    memcached_1 = new_memcached(semian: semian_options)
    memcached_1.semian_resource.acquire do
      memcached_2 = new_memcached(semian: semian_options)
      memcached_2.semian_resource.acquire do
        assert_raises Memcached::ResourceBusyError do
          new_memcached(semian: semian_options).set("foo", "bar")
        end
      end
    end
  end

  def test_semian_identifier
    assert_equal(:memcached_foo, new_memcached(semian: {name: :foo}).semian_identifier)
    assert_equal(:memcached, new_memcached(semian: {name: nil}).semian_identifier)
  end

  def test_query_instrumentation
    client = new_memcached

    notified = false
    subscriber = Semian.subscribe do |event, resource, scope, adapter|
      notified = true
      assert_equal :success, event
      assert_equal Semian[:memcached_testing], resource
      assert_equal :query, scope
      assert_equal :memcached, adapter
    end

    client.set("foo", "bar")

    assert notified, "No notifications has been emitted"
  ensure
    Semian.unsubscribe(subscriber)
  end

  def test_resource_acquisition_for_query
    client = new_memcached
    client.set("foo", "bar")

    Semian[:memcached_testing].acquire do
      assert_raises(Memcached::ResourceBusyError) do
        client.get("foo")
      end
    end
  end

  def test_resource_timeout_on_query
    memcached_1 = new_memcached
    memcached_1.set("foo", "bar")
    memcached_1.set("bar", "bar")

    Toxiproxy[:semian_test_memcached].downstream(:latency, latency: 500).apply do
      # needs to be in seperate processes since the memcached gem will
      # acquire the GVL and not release it until the #get returns
      pid = Process.fork do
        memcached_2 = new_memcached
        memcached_2.get("foo")
      end
      Process.detach(pid)

      sleep(0.1)

      assert_raises(Memcached::ResourceBusyError) do
        memcached_1.get("bar")
      end
    end
  end

  def test_circuit_breaker_is_disabled
    client = new_memcached
    assert_nil client.semian_resource.circuit_breaker
  end

  private

  TOXIPROXY_MEMCACHED = "#{SemianConfig['toxiproxy_upstream_host']}:#{SemianConfig['memcached_toxiproxy_port']}"
  SEMIAN_OPTIONS = {
    name: :testing,
    tickets: 1,
    timeout: 0,
  }
  MEMCACHED_OPTIONS = {
    servers: TOXIPROXY_MEMCACHED,
    auto_eject_hosts: false,
    timeout: 0.5,
    semian: SEMIAN_OPTIONS,
  }

  def new_memcached(**options)
    options = MEMCACHED_OPTIONS.merge(options)
    servers = Array(options.delete(:servers))
    Memcached.new(servers, options)
  end
end
