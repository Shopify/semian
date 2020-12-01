module Semian
  class Resource #:nodoc:
    attr_reader :tickets, :name

    class << Semian::Resource
      # Ensure that there can only be one resource of a given type
      def instance(name, **kwargs)
        Semian.resources[name] ||= ProtectedResource.new(name, new(name, **kwargs), nil)
      end
    end

    def initialize(name, tickets: nil, quota: nil, permissions: 0660, timeout: 0, is_global: false)
      if Semian.semaphores_enabled?
        initialize_semaphore(name, tickets, quota, permissions, timeout, is_global) if respond_to?(:initialize_semaphore)
      else
        Semian.issue_disabled_semaphores_warning
      end
      @name = name
    end

    def reset_registered_workers!
    end

    def destroy
    end

    def unregister_worker
    end

    def acquire(*)
      wait_time = 0
      yield wait_time
    end

    def count
      0
    end

    def tickets
      0
    end

    def registered_workers
      0
    end

    def semid
      0
    end

    def key
      '0x00000000'
    end

    def in_use?
      false
    end
  end
end
