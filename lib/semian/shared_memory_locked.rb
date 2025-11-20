# frozen_string_literal: true

module Semian
  # SharedMemory implementation using semaphore locks instead of atomics
  # Useful for benchmarking and platforms without atomic support
  class SharedMemoryLocked
    SIZEOF_INT = 4
    SIZEOF_DOUBLE = 8

    attr_reader :size, :shm_id, :sem_id

    def initialize(resource_name, key:, size:)
      @resource = Semian::Resource.new(resource_name, tickets: 1)
      @shm_id, @created = @resource.create_shared_memory(key, size)
      @addr = @resource.attach_shared_memory(@shm_id)
      @size = size
      @sem_id = @resource.semid
    end

    def created?
      @created
    end

    def write_int(offset, value)
      validate_bounds!(offset, SIZEOF_INT)
      with_lock do
        @resource.atomic_int_store(@addr + offset, value)
      end
    end

    def read_int(offset)
      validate_bounds!(offset, SIZEOF_INT)
      with_lock do
        @resource.atomic_int_load(@addr + offset)
      end
    end

    def increment_int(offset, delta = 1)
      validate_bounds!(offset, SIZEOF_INT)
      with_lock do
        old_value = @resource.atomic_int_load(@addr + offset)
        @resource.atomic_int_store(@addr + offset, old_value + delta)
        old_value
      end
    end

    def exchange_int(offset, value)
      validate_bounds!(offset, SIZEOF_INT)
      with_lock do
        old_value = @resource.atomic_int_load(@addr + offset)
        @resource.atomic_int_store(@addr + offset, value)
        old_value
      end
    end

    def write_double(offset, value)
      validate_bounds!(offset, SIZEOF_DOUBLE)
      with_lock do
        @resource.atomic_double_store(@addr + offset, value)
      end
    end

    def read_double(offset)
      validate_bounds!(offset, SIZEOF_DOUBLE)
      with_lock do
        @resource.atomic_double_load(@addr + offset)
      end
    end

    def exchange_double(offset, value)
      validate_bounds!(offset, SIZEOF_DOUBLE)
      with_lock do
        old_value = @resource.atomic_double_load(@addr + offset)
        @resource.atomic_double_store(@addr + offset, value)
        old_value
      end
    end

    def detach
      return unless @addr

      @resource.detach_shared_memory(@addr)
      @addr = nil
    end

    def destroy
      detach if @addr
      return unless @shm_id

      @resource.destroy_shared_memory(@shm_id)
      @shm_id = nil
    end

    private

    def validate_bounds!(offset, element_size)
      if offset < 0
        raise ArgumentError, "Offset cannot be negative: #{offset}"
      end

      if offset + element_size > @size
        raise ArgumentError,
          "Access at offset #{offset} (#{element_size} bytes) exceeds allocated size #{@size}"
      end
    end

    def with_lock(&block)
      @resource.acquire(&block)
    end
  end
end
