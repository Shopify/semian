module Semian
  module SysVSharedMemory #:nodoc:
    def self.included(base)
      # This is a helper method for wrapping a method in :synchronize
      # Its usage is to be called from C: where rb_define_method() is originally
      #   used, define_method_with_synchronize() is used instead, which calls this
      def base.do_with_sync(*names)
        names.each do |name|
          new_name = "#{name}_inner"
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
      raise NotImplementedError
    end

    def bind_initialize_memory_callback
      raise NotImplementedError
    end
  end
end
