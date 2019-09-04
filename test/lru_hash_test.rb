require 'test_helper'

class TestLRUHash < Minitest::Test
  def setup
    Semian.thread_safe = true
    @lru_hash = LRUHash.new(max_size: 0)
  end

  def test_set_get_item
    circuit_breaker = create_circuit_breaker('a')
    @lru_hash.set('key', circuit_breaker)
    assert_equal circuit_breaker, @lru_hash.get('key')
  end

  def test_set_get_item_with_thread_safe_disabled
    Semian.thread_safe = false
    @lru_hash = LRUHash.new
    circuit_breaker = create_circuit_breaker('a')
    @lru_hash.set('key', circuit_breaker)
    assert_equal circuit_breaker, @lru_hash.get('key')
  end

  def test_set_get_item_with_thread_safe_enabled
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

  def test_set_cleans_resources_if_last_error_has_expired
    @lru_hash.set('b', create_circuit_breaker('b', true, false, 1000))

    Timecop.travel(2000) do
      @lru_hash.set('d', create_circuit_breaker('d'))
      assert_equal 1, @lru_hash.table.count
    end
  end

  def test_set_does_not_clean_resources_if_last_error_has_not_expired
    @lru_hash.set('b', create_circuit_breaker('b', true, false, 1000))

    Timecop.travel(600) do
      @lru_hash.set('d', create_circuit_breaker('d'))
      assert_equal 2, @lru_hash.table.count
    end
  end

  def test_set_cleans_resources_if_minimum_time_is_reached
    @lru_hash.set('a', create_circuit_breaker('a', true, false, 1000))
    @lru_hash.set('b', create_circuit_breaker('b', false))
    @lru_hash.set('c', create_circuit_breaker('c', false))

    Timecop.travel(600) do
      @lru_hash.set('d', create_circuit_breaker('d'))
      assert_equal 2, @lru_hash.table.count
    end
  end

  def test_set_does_not_cleans_resources_if_minimum_time_is_not_reached
    @lru_hash.set('a', create_circuit_breaker('a'))
    @lru_hash.set('b', create_circuit_breaker('b', false))
    @lru_hash.set('c', create_circuit_breaker('c'))

    assert_equal 3, @lru_hash.table.count
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

  def test_clean_instrumentation
    @lru_hash.set('a', create_circuit_breaker('a', true, false, 1000))
    @lru_hash.set('b', create_circuit_breaker('b', true, false, 1000))
    @lru_hash.set('c', create_circuit_breaker('c', true, false, 1000))

    notified = false
    subscriber = Semian.subscribe do |event, resource, scope, adapter, payload|
      next unless event == :lru_hash_gc
      notified = true
      assert_equal @lru_hash, resource
      assert_nil scope
      assert_nil adapter
      assert_equal 4, payload[:size]
      assert_equal 4, payload[:examined]
      assert_equal 3, payload[:cleared]
      refute_nil payload[:elapsed]
    end

    Timecop.travel(2000) do
      @lru_hash.set('d', create_circuit_breaker('d'))
    end

    assert notified, 'No notifications has been emitted'
  ensure
    Semian.unsubscribe(subscriber)
  end

  def test_monotonically_increasing
    start_time = Time.now

    notification = 0
    subscriber = Semian.subscribe do |event, _resource, _scope, _adapter, payload|
      next unless event == :lru_hash_gc

      notification += 1
      if notification < 5
        assert_equal notification, payload[:size]
        assert_equal 1, payload[:examined]
      elsif notification == 5
        # At this point, the table looks like: [a, c, b, d, e]
        assert_equal notification, payload[:size]
        assert_equal 3, payload[:examined]
      else
        assert_nil true
      end
    end

    assert_monotonic = lambda do
      previous_timestamp = start_time
      @lru_hash.table.each do |key, val|
        assert val.updated_at > previous_timestamp, "Timestamp for #{key} was not monotonically increasing"
      end
    end

    @lru_hash.set('a', create_circuit_breaker('a'))
    @lru_hash.set('b', create_circuit_breaker('b'))
    @lru_hash.set('c', create_circuit_breaker('c'))

    # Before: [a, b, c]
    # After: [a, c, b]
    Timecop.travel(Semian.minimum_lru_time - 1) do
      @lru_hash.get('b')
      assert_monotonic.call
    end

    # Before: [a, c, b]
    # After: [a, c, b, d]
    Timecop.travel(Semian.minimum_lru_time - 1) do
      @lru_hash.set('d', create_circuit_breaker('d'))
      assert_monotonic.call
    end

    # Before: [a, c, b, d]
    # After: [b, d, e]
    Timecop.travel(Semian.minimum_lru_time) do
      @lru_hash.set('e', create_circuit_breaker('e'))
      assert_monotonic.call
    end
  ensure
    Semian.unsubscribe(subscriber)
  end

  def test_max_size
    lru_hash = LRUHash.new(max_size: 3)
    lru_hash.set('a', create_circuit_breaker('a'))
    lru_hash.set('b', create_circuit_breaker('b'))
    lru_hash.set('c', create_circuit_breaker('c'))
    assert_equal 3, lru_hash.table.length

    Timecop.travel(Semian.minimum_lru_time) do
      # [a, b, c] are older than the min_time, so they get garbage collected.
      lru_hash.set('d', create_circuit_breaker('d'))
      assert_equal 1, lru_hash.table.length
    end
  end

  def test_max_size_overflow
    lru_hash = LRUHash.new(max_size: 3)
    lru_hash.set('a', create_circuit_breaker('a'))
    lru_hash.set('b', create_circuit_breaker('b'))
    assert_equal 2, lru_hash.table.length

    Timecop.travel(Semian.minimum_lru_time) do
      # [a, b] are older than the min_time, but the hash isn't full, so
      # there's no garbage collection.
      lru_hash.set('c', create_circuit_breaker('c'))
      assert_equal 3, lru_hash.table.length
    end

    Timecop.travel(Semian.minimum_lru_time + 1) do
      # [a, b] are beyond the min_time, but [c] isn't.
      lru_hash.set('d', create_circuit_breaker('d'))
      assert_equal 2, lru_hash.table.length
    end
  end

  private

  def create_circuit_breaker(name, exceptions = true, bulkhead = false, error_timeout = 0)
    implementation = Semian.thread_safe? ? ::Semian::Simple : ::Semian::ThreadSafe
    circuit_breaker = Semian::CircuitBreaker.new(
      name,
      success_threshold: 0,
      error_threshold: 1,
      error_timeout:  error_timeout,
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
