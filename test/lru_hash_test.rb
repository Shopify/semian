require 'test_helper'

class TestLRUHash < Minitest::Test
  def setup
    Semian.send(:define_thread_safe, true)
    @lru_hash = LRUHash.new(minimum_time_in_lru: 300)
  end

  def test_set_get_item
    circuit_breaker = create_circuit_breaker('a')
    @lru_hash.set('key', circuit_breaker)
    assert_equal circuit_breaker, @lru_hash.get('key')
  end

  def test_set_get_item_with_thread_safe_disabled
    Semian.send(:define_thread_safe, false)
    @lru_hash = LRUHash.new(minimum_time_in_lru: 300)

    circuit_breaker = create_circuit_breaker('a')
    @lru_hash.set('key', circuit_breaker)
    assert_equal circuit_breaker, @lru_hash.get('key')
  end

  def test_set_get_item_with_thread_safe_enabled
    Semian.send(:define_thread_safe, true)
    circuit_breaker = create_circuit_breaker('a')
    @lru_hash.set('key', circuit_breaker)
    assert_equal circuit_breaker, @lru_hash.get('key')
  end

  def test_remove_item
    @lru_hash.set('a', create_circuit_breaker('a'))
    @lru_hash.set('b', create_circuit_breaker('b'))
    @lru_hash.set('c', create_circuit_breaker('c'))

    assert_equal 3, @lru_hash.count

    @lru_hash.delete('b')
    assert_equal 2, @lru_hash.table.count
    assert_equal @lru_hash.table.values.last, @lru_hash.get('c')
    assert_equal @lru_hash.table.values.first, @lru_hash.get('a')
  end

  def test_get_moves_the_item_at_the_top
    @lru_hash.set('a', create_circuit_breaker('a'))
    @lru_hash.set('b', create_circuit_breaker('b'))
    @lru_hash.set('c', create_circuit_breaker('c'))

    assert_equal 3, @lru_hash.table.count
    @lru_hash.get('a') # Reading the value will move the resource at the tail position
    assert_equal @lru_hash.table.values.last, @lru_hash.get('a')
    assert_equal @lru_hash.table.values.first, @lru_hash.get('b')
  end

  def test_set_cleans_resources_if_minimum_time_is_reached
    @lru_hash.set('a', create_circuit_breaker('a'))
    @lru_hash.set('b', create_circuit_breaker('b', false))

    Timecop.travel(600) do
      @lru_hash.set('c', create_circuit_breaker('c'))
      assert_equal 2, @lru_hash.table.count
    end
  end

  def test_set_does_not_cleans_resources_if_minimum_time_is_not_reached
    @lru_hash.set('a', create_circuit_breaker('a'))
    @lru_hash.set('b', create_circuit_breaker('b', false))
    @lru_hash.set('c', create_circuit_breaker('c'))

    assert_equal 3, @lru_hash.table.count
  end

  def test_set_cleans_a_maximum_of_two_resources
    @lru_hash.set('a', create_circuit_breaker('a', false))
    @lru_hash.set('b', create_circuit_breaker('b', false))
    @lru_hash.set('c', create_circuit_breaker('c', false))

    Timecop.travel(600) do
      @lru_hash.set('d', create_circuit_breaker('d'))
      assert_equal 2, @lru_hash.table.count
    end
  end

  def test_set_does_not_clean_bulkhead
    @lru_hash.set('a', create_circuit_breaker('a'))
    @lru_hash.set('b', create_circuit_breaker('b', false, true))

    Timecop.travel(600) do
      @lru_hash.set('c', create_circuit_breaker('c'))
      assert_equal 3, @lru_hash.table.count
    end
  end

  def test_keys
    @lru_hash.set('a', create_circuit_breaker('a'))
    assert_equal ['a'], @lru_hash.keys
  end

  def test_delete
    @lru_hash.set('a', create_circuit_breaker('a'))
    assert @lru_hash.get('a')

    @lru_hash.delete('a')
    assert_nil @lru_hash.get('a')
  end

  def test_clear
    @lru_hash.set('a', create_circuit_breaker('a'))
    @lru_hash.clear
    assert @lru_hash.empty?
  end

  private

  def create_circuit_breaker(name, exceptions = true, bulkhead = false)
    implementation = Semian.thread_safe? ? ::Semian::Simple : ::Semian::ThreadSafe
    circuit_breaker = Semian::CircuitBreaker.new(
      name,
      success_threshold: 0,
      error_threshold: 1,
      error_timeout: 0,
      exceptions: [::Semian::BaseError],
      half_open_resource_timeout: nil,
      implementation: implementation,
    )
    circuit_breaker.mark_failed(nil) if exceptions
    Semian::ProtectedResource.new(name, create_bulkhead(name, bulkhead), circuit_breaker)
  end

  def create_bulkhead(name, bulkhead)
    return nil unless bulkhead
    Semian::Resource.new(name, tickets: 1, quota: nil, permissions: 0660, timeout: 0)
  end
end
