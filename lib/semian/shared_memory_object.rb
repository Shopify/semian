module Semian
  class SharedMemoryObject #:nodoc:
    @type_size = {}
    def self.sizeof(type)
      size = (@type_size[type.to_sym] ||= (respond_to?(:_sizeof) ? _sizeof(type.to_sym) : 0))
      raise TypeError.new("#{type} is not a valid C type") if size <= 0
      size
    end

    def semid
      -1
    end

    def shmid
      -1
    end

    def execute_atomically
      yield if block_given?
    end

    def shared?
      @using_shared_memory ||= Semian.extension_loaded && @using_shared_memory
    end

    def destroy
      _destroy if respond_to?(:_destroy) && @using_shared_memory
    end

    def acquire_memory_object(name, data_layout, permissions)
      return @using_shared_memory = false unless Semian.extension_loaded && respond_to?(:_acquire)

      byte_size = data_layout.inject(0) { |sum, type| sum + ::Semian::SharedMemoryObject.sizeof(type) }
      raise TypeError.new("Given data layout is 0 bytes: #{data_layout.inspect}") if byte_size <= 0
      # Calls C layer to acquire/create a memory block, calling #bind_init_fn in the process, see below
      _acquire(name, byte_size, permissions)
      @using_shared_memory = true
    end

    def bind_init_fn
      # Concrete classes must implement this in a subclass in C to bind a callback function of type
      # void (*object_init_fn)(size_t byte_size, void *dest, void *prev_data, size_t prev_data_byte_size);
      # to location ptr->object_init_fn, where ptr is a semian_shm_object*
      # It is called when memory needs to be initialized or resized, possibly using previous memory
      raise NotImplementedError
    end
  end
end
