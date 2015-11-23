module Semian
  module SysVSharedMemory #:nodoc:
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

    def synchronize
      yield if block_given?
    end

    def destroy
      super
    end

    private

    def acquire_memory_object(*)
      # Concrete classes must call this method before accessing shared memory
      # If SysV is enabled, a C method overrides this stub and returns true if acquiring succeeds
      false
    end

    def bind_initialize_memory_callback
      # Concrete classes must implement this in a subclass in C to bind a callback function of type
      # void (*initialize_memory)(size_t byte_size, void *dest, void *prev_data, size_t prev_data_byte_size);
      # to location ptr->initialize_memory, where ptr is a semian_shm_object*
      # It is called when memory needs to be initialized or resized, possibly using previous memory
      raise NotImplementedError
    end
  end
end
