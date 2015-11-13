module Semian
  module SysVSharedMemory #:nodoc:
    @type_size = {}
    def self.sizeof(type)
      size = (@type_size[type.to_sym] ||= (respond_to?(:_sizeof) ? _sizeof(type.to_sym) : 0))
      raise TypeError.new("#{type} is not a valid C type") if size <= 0
      size
    end

    def self.included(base)
      def base.do_with_sync(*names)
        names.each do |name|
          new_name = "#{name}_inner".freeze.to_sym
          alias_method new_name, name
          private new_name
          define_method(name) do |*args, &block|
            synchronize do
              method(new_name).call(*args, &block)
            end
          end
        end
      end
    end

    def semid
      -1
    end

    def shmid
      -1
    end

    def synchronize(&block)
      if respond_to?(:_synchronize) && @using_shared_memory
        _synchronize(&block)
      else
        yield if block_given?
      end
    end

    alias_method :transaction, :synchronize

    def destroy
      if respond_to?(:_destroy) && @using_shared_memory
        _destroy
      else
        super
      end
    end

    private

    def shared?
      @using_shared_memory
    end

    def acquire_memory_object(name, data_layout, permissions)
      return @using_shared_memory = false unless Semian.semaphores_enabled? && respond_to?(:_acquire)

      byte_size = data_layout.inject(0) { |sum, type| sum + ::Semian::SysVSharedMemory.sizeof(type) }
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
