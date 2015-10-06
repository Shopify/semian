module Semian
  class SharedMemoryObject
    @@type_size = {}

    def self.shared?
      false
    end
    def self.sizeof(type)
      size = (@@type_size[type.to_sym] ||= (respond_to?(:_sizeof) ? _sizeof(type.to_sym) : 0))
      if size <=0
        raise TypeError.new("#{type} is not a valid C type")
      end
      size
    end

    def acquire(name, data_layout, permissions)
      byte_size = data_layout.inject(0) { |sum,type| sum+self.class.sizeof(type) }
      if respond_to?(:_acquire) and byte_size > 0
        # Will succeed only if #bind_init_fn is defined
        # _acquire will call bind_init_fn to bind a function of type
        # void (*object_init_fn)(size_t byte_size, void *dest, void *prev_data, size_t prev_data_byte_size);
        # To the C instance object
        _acquire(name, byte_size, permissions)
        true
      else
        false
      end
    end

    def bind_init_fn
      # Concrete classes must override this in a subclass in C
      raise NotImplementedError
    end

    def semid
      -1
    end

    def shmid
      -1
    end



  end
end
