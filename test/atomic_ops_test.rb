# frozen_string_literal: true

require "test_helper"

class TestAtomicOps < Minitest::Test
  def setup
    skip("Atomic operations not supported on this platform") unless Semian.sysv_semaphores_supported?
    @cleanup_shm_ids = []
    @cleanup_addrs = []
  end

  def teardown
    @cleanup_addrs.each do |addr|
      resource.detach_shared_memory(addr)
    rescue
      nil
    end

    @cleanup_shm_ids.each do |shm_id|
      resource.destroy_shared_memory(shm_id)
    rescue
      nil
    end
  end

  def resource
    @resource ||= Semian::Resource.new(:test_atomic, tickets: 1)
  end

  def test_atomic_int_load_and_store
    key = 0xA0000001
    size = 16

    shm_id, _created = resource.create_shared_memory(key, size)
    @cleanup_shm_ids << shm_id

    addr = resource.attach_shared_memory(shm_id)
    @cleanup_addrs << addr

    resource.atomic_int_store(addr, 42)
    value = resource.atomic_int_load(addr)

    assert_equal(42, value)
  end

  def test_atomic_int_fetch_add
    key = 0xA0000002
    size = 16

    shm_id, _created = resource.create_shared_memory(key, size)
    @cleanup_shm_ids << shm_id

    addr = resource.attach_shared_memory(shm_id)
    @cleanup_addrs << addr

    resource.atomic_int_store(addr, 10)

    old_value = resource.atomic_int_fetch_add(addr, 5)

    assert_equal(10, old_value, "fetch_add should return old value")

    new_value = resource.atomic_int_load(addr)

    assert_equal(15, new_value, "value should be updated")
  end

  def test_atomic_int_exchange
    key = 0xA0000003
    size = 16

    shm_id, _created = resource.create_shared_memory(key, size)
    @cleanup_shm_ids << shm_id

    addr = resource.attach_shared_memory(shm_id)
    @cleanup_addrs << addr

    resource.atomic_int_store(addr, 100)

    old_value = resource.atomic_int_exchange(addr, 200)

    assert_equal(100, old_value, "exchange should return old value")

    new_value = resource.atomic_int_load(addr)

    assert_equal(200, new_value, "value should be swapped")
  end

  def test_atomic_double_load_and_store
    key = 0xA0000004
    size = 16

    shm_id, _created = resource.create_shared_memory(key, size)
    @cleanup_shm_ids << shm_id

    addr = resource.attach_shared_memory(shm_id)
    @cleanup_addrs << addr

    resource.atomic_double_store(addr, 3.14159)
    value = resource.atomic_double_load(addr)

    assert_in_delta(3.14159, value, 0.00001)
  end

  def test_atomic_double_exchange
    key = 0xA0000005
    size = 16

    shm_id, _created = resource.create_shared_memory(key, size)
    @cleanup_shm_ids << shm_id

    addr = resource.attach_shared_memory(shm_id)
    @cleanup_addrs << addr

    resource.atomic_double_store(addr, 0.5)

    old_value = resource.atomic_double_exchange(addr, 0.75)

    assert_in_delta(0.5, old_value, 0.00001)

    new_value = resource.atomic_double_load(addr)

    assert_in_delta(0.75, new_value, 0.00001)
  end

  def test_concurrent_increments_no_lost_updates
    key = 0xA0000006
    size = 16

    shm_id, _created = resource.create_shared_memory(key, size)
    @cleanup_shm_ids << shm_id

    addr = resource.attach_shared_memory(shm_id)
    @cleanup_addrs << addr

    resource.atomic_int_store(addr, 0)

    num_processes = 10
    increments_per_process = 1000

    pids = []
    num_processes.times do
      pid = fork do
        child_addr = resource.attach_shared_memory(shm_id)

        increments_per_process.times do
          resource.atomic_int_fetch_add(child_addr, 1)
        end

        resource.detach_shared_memory(child_addr)
        exit(0)
      end
      pids << pid
    end

    pids.each { |pid| Process.wait(pid) }

    final_count = resource.atomic_int_load(addr)
    expected_count = num_processes * increments_per_process

    assert_equal(
      expected_count,
      final_count,
      "Atomic increments should not lose any updates. " \
        "Expected #{expected_count}, got #{final_count}",
    )
  end

  def test_concurrent_double_updates
    key = 0xA0000007
    size = 16

    shm_id, _created = resource.create_shared_memory(key, size)
    @cleanup_shm_ids << shm_id

    addr = resource.attach_shared_memory(shm_id)
    @cleanup_addrs << addr

    resource.atomic_double_store(addr, 0.0)

    num_processes = 5
    values = [0.1, 0.2, 0.3, 0.4, 0.5]

    pids = []
    values.each_with_index do |val, i|
      pid = fork do
        child_addr = resource.attach_shared_memory(shm_id)
        resource.atomic_double_store(child_addr, val)
        resource.detach_shared_memory(child_addr)
        exit(0)
      end
      pids << pid
    end

    pids.each { |pid| Process.wait(pid) }

    final_value = resource.atomic_double_load(addr)

    assert_includes(
      values,
      final_value,
      "Final value #{final_value} should be one of the written values",
    )
  end

  def test_atomic_int_with_negative_increment
    key = 0xA0000008
    size = 16

    shm_id, _created = resource.create_shared_memory(key, size)
    @cleanup_shm_ids << shm_id

    addr = resource.attach_shared_memory(shm_id)
    @cleanup_addrs << addr

    resource.atomic_int_store(addr, 100)

    old_value = resource.atomic_int_fetch_add(addr, -30)

    assert_equal(100, old_value)

    new_value = resource.atomic_int_load(addr)

    assert_equal(70, new_value)
  end

  def test_atomic_operations_with_zero
    key = 0xA0000009
    size = 16

    shm_id, _created = resource.create_shared_memory(key, size)
    @cleanup_shm_ids << shm_id

    addr = resource.attach_shared_memory(shm_id)
    @cleanup_addrs << addr

    resource.atomic_int_store(addr, 0)

    assert_equal(0, resource.atomic_int_load(addr))

    resource.atomic_double_store(addr, 0.0)

    assert_in_delta(0.0, resource.atomic_double_load(addr), 0.00001)
  end

  def test_atomic_double_boundary_values
    key = 0xA000000A
    size = 16

    shm_id, _created = resource.create_shared_memory(key, size)
    @cleanup_shm_ids << shm_id

    addr = resource.attach_shared_memory(shm_id)
    @cleanup_addrs << addr

    [0.0, 0.001, 0.5, 0.999, 1.0].each do |test_value|
      resource.atomic_double_store(addr, test_value)
      loaded_value = resource.atomic_double_load(addr)

      assert_in_delta(
        test_value,
        loaded_value,
        0.00001,
        "Value #{test_value} should round-trip correctly",
      )
    end
  end
end
