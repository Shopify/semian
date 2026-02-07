# frozen_string_literal: true

require "test_helper"

class TestSharedMemory < Minitest::Test
  def setup
    skip("Shared memory not supported on this platform") unless Semian.sysv_semaphores_supported?
    @cleanup_shms = []
  end

  def teardown
    @cleanup_shms.each do |shm|
      shm.destroy
    rescue
      nil
    end
  end

  def test_create_shared_memory
    shm = Semian::SharedMemory.new(:test_shm_create, key: 0x12345678, size: 1024)
    @cleanup_shms << shm

    assert(shm.created?, "Expected created flag to be true for new segment")
    assert_kind_of(Integer, shm.shm_id)
    assert_operator(shm.shm_id, :>, 0)
    assert_equal(1024, shm.size)
  end

  def test_attach_to_existing_shared_memory
    key = 0x12345679
    size = 1024

    shm1 = Semian::SharedMemory.new(:test_shm_existing1, key: key, size: size)
    @cleanup_shms << shm1

    assert(shm1.created?, "First call should create new segment")

    shm2 = Semian::SharedMemory.new(:test_shm_existing2, key: key, size: size)
    @cleanup_shms << shm2

    assert_equal(shm1.shm_id, shm2.shm_id, "Expected same shm_id for existing segment")
    assert_equal(false, shm2.created?, "Expected created flag to be false for existing segment")
  end

  def test_write_and_read_int
    shm = Semian::SharedMemory.new(:test_int_rw, key: 0x1234567A, size: 1024)
    @cleanup_shms << shm

    shm.write_int(0, 42)
    value = shm.read_int(0)

    assert_equal(42, value)
  end

  def test_write_and_read_double
    shm = Semian::SharedMemory.new(:test_double_rw, key: 0x1234567B, size: 1024)
    @cleanup_shms << shm

    shm.write_double(0, 3.14159)
    value = shm.read_double(0)

    assert_in_delta(3.14159, value, 0.00001)
  end

  def test_increment_int
    shm = Semian::SharedMemory.new(:test_increment, key: 0x1234567C, size: 1024)
    @cleanup_shms << shm

    shm.write_int(0, 10)
    old_value = shm.increment_int(0, 5)

    assert_equal(10, old_value, "increment_int should return old value")
    assert_equal(15, shm.read_int(0), "value should be incremented")
  end

  def test_exchange_int
    shm = Semian::SharedMemory.new(:test_exchange_int, key: 0x1234567D, size: 1024)
    @cleanup_shms << shm

    shm.write_int(0, 100)
    old_value = shm.exchange_int(0, 200)

    assert_equal(100, old_value, "exchange_int should return old value")
    assert_equal(200, shm.read_int(0), "value should be swapped")
  end

  def test_exchange_double
    shm = Semian::SharedMemory.new(:test_exchange_double, key: 0x1234567E, size: 1024)
    @cleanup_shms << shm

    shm.write_double(0, 0.5)
    old_value = shm.exchange_double(0, 0.75)

    assert_in_delta(0.5, old_value, 0.00001)
    assert_in_delta(0.75, shm.read_double(0), 0.00001)
  end

  def test_bounds_checking_negative_offset
    shm = Semian::SharedMemory.new(:test_bounds_neg, key: 0x1234567F, size: 1024)
    @cleanup_shms << shm

    error = assert_raises(ArgumentError) do
      shm.read_int(-4)
    end

    assert_match(/negative/, error.message)
  end

  def test_bounds_checking_overflow_int
    shm = Semian::SharedMemory.new(:test_bounds_overflow_int, key: 0x12345680, size: 1024)
    @cleanup_shms << shm

    error = assert_raises(ArgumentError) do
      shm.write_int(1021, 42) # 1021 + 4 = 1025 > 1024
    end

    assert_match(/exceeds allocated size/, error.message)
  end

  def test_bounds_checking_overflow_double
    shm = Semian::SharedMemory.new(:test_bounds_overflow_double, key: 0x12345681, size: 1024)
    @cleanup_shms << shm

    error = assert_raises(ArgumentError) do
      shm.write_double(1017, 3.14) # 1017 + 8 = 1025 > 1024
    end

    assert_match(/exceeds allocated size/, error.message)
  end

  def test_bounds_checking_exact_boundary
    shm = Semian::SharedMemory.new(:test_bounds_exact, key: 0x12345682, size: 1024)
    @cleanup_shms << shm

    # Should work - exactly at boundary
    shm.write_int(1020, 42) # 1020 + 4 = 1024 (exact)

    assert_equal(42, shm.read_int(1020))

    shm.write_double(1016, 1.5) # 1016 + 8 = 1024 (exact)

    assert_in_delta(1.5, shm.read_double(1016), 0.00001)
  end

  def test_cross_process_shared_memory
    key = 0x12345683
    size = 16

    shm = Semian::SharedMemory.new(:test_cross_process, key: key, size: size)
    @cleanup_shms << shm

    # Parent writes a value
    shm.write_int(0, 12345)

    pid = fork do
      child_shm = Semian::SharedMemory.new(:test_cross_process_child, key: key, size: size)
      value = child_shm.read_int(0)

      # Write a new value
      child_shm.write_int(0, 67890)
      child_shm.destroy

      exit(value == 12345 ? 0 : 1)
    end

    Process.wait(pid)

    assert_equal(0, $?.exitstatus, "Child should have read correct value")

    # Parent reads child's value
    value = shm.read_int(0)

    assert_equal(67890, value, "Parent should read child's value")
  end

  def test_concurrent_increments
    key = 0x12345684
    size = 16

    shm = Semian::SharedMemory.new(:test_concurrent, key: key, size: size)
    @cleanup_shms << shm

    shm.write_int(0, 0)

    num_processes = 5
    increments_per_process = 100

    pids = []
    num_processes.times do
      pid = fork do
        child_shm = Semian::SharedMemory.new(:test_concurrent_child, key: key, size: size)

        increments_per_process.times do
          child_shm.increment_int(0, 1)
        end

        child_shm.detach
        exit(0)
      end
      pids << pid
    end

    pids.each { |pid| Process.wait(pid) }

    final_count = shm.read_int(0)
    expected_count = num_processes * increments_per_process

    assert_equal(
      expected_count,
      final_count,
      "Atomic increments should not lose any updates",
    )
  end

  def test_destroy_cleans_up
    shm = Semian::SharedMemory.new(:test_destroy, key: 0x12345685, size: 1024)

    shm.destroy

    # Destroy should be idempotent
    shm.destroy
  end
end
