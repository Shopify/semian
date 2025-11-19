# frozen_string_literal: true

require "test_helper"

class TestSharedMemory < Minitest::Test
  def setup
    skip("Shared memory not supported on this platform") unless Semian.sysv_semaphores_supported?
    @cleanup_shm_ids = []
    @cleanup_addrs = []
  end

  def teardown
    # Clean up any attached memory
    @cleanup_addrs.each do |addr|
      resource.detach_shared_memory(addr)
    rescue
      nil
    end

    # Clean up any created shared memory segments
    @cleanup_shm_ids.each do |shm_id|
      resource.destroy_shared_memory(shm_id)
    rescue
      nil
    end
  end

  def resource
    @resource ||= Semian::Resource.new(:test_shm, tickets: 1)
  end

  def test_create_shared_memory
    key = 0x12345678
    size = 1024

    shm_id, created = resource.create_shared_memory(key, size)
    @cleanup_shm_ids << shm_id

    assert_kind_of(Integer, shm_id)
    assert_operator(shm_id, :>, 0, "Expected positive shm_id, got #{shm_id}")
    assert(created, "Expected created flag to be true for new segment")
  end

  def test_attach_to_existing_shared_memory
    key = 0x12345679
    size = 1024

    # Create segment first
    shm_id1, created1 = resource.create_shared_memory(key, size)
    @cleanup_shm_ids << shm_id1

    assert(created1, "First call should create new segment")

    # Try to create again - should attach to existing
    shm_id2, created2 = resource.create_shared_memory(key, size)

    assert_equal(shm_id1, shm_id2, "Expected same shm_id for existing segment")
    assert_equal(false, created2, "Expected created flag to be false for existing segment")
  end

  def test_attach_and_detach_shared_memory
    key = 0x1234567A
    size = 1024

    shm_id, _created = resource.create_shared_memory(key, size)
    @cleanup_shm_ids << shm_id

    addr = resource.attach_shared_memory(shm_id)
    @cleanup_addrs << addr

    assert_kind_of(Integer, addr)
    assert_operator(addr, :>, 0, "Expected positive address, got #{addr}")

    # Detach should succeed and return nil
    result = resource.detach_shared_memory(addr)

    assert_nil(result, "detach_shared_memory should return nil")
    @cleanup_addrs.delete(addr)
  end

  def test_destroy_shared_memory
    key = 0x1234567B
    size = 1024

    shm_id, _created = resource.create_shared_memory(key, size)

    # Destroy should succeed and return true
    result = resource.destroy_shared_memory(shm_id)

    assert(result)

    # Try to destroy again - should not raise (idempotent)
    result = resource.destroy_shared_memory(shm_id)

    assert(result)
  end

  def test_attach_raises_on_invalid_shm_id
    invalid_shm_id = 999999

    error = assert_raises(Semian::SyscallError) do
      resource.attach_shared_memory(invalid_shm_id)
    end

    assert_match(/shmat.*failed/, error.message)
  end

  def test_detach_raises_on_invalid_address
    invalid_addr = 123456

    error = assert_raises(Semian::SyscallError) do
      resource.detach_shared_memory(invalid_addr)
    end

    assert_match(/shmdt.*failed/, error.message)
  end

  def test_create_raises_on_invalid_arguments
    assert_raises(TypeError) do
      resource.create_shared_memory("not_an_int", 1024)
    end

    assert_raises(TypeError) do
      resource.create_shared_memory(0x123, "not_an_int")
    end
  end

  def test_multiple_attachments_same_process
    key = 0x1234567C
    size = 1024

    shm_id, _created = resource.create_shared_memory(key, size)
    @cleanup_shm_ids << shm_id

    # Attach multiple times in the same process
    addr1 = resource.attach_shared_memory(shm_id)
    addr2 = resource.attach_shared_memory(shm_id)

    @cleanup_addrs << addr1
    @cleanup_addrs << addr2

    # Both addresses should be valid integers
    assert_kind_of(Integer, addr1)
    assert_kind_of(Integer, addr2)

    # NOTE: The addresses may or may not be the same depending on the platform
    # What matters is that both attachments succeed
  end
end
