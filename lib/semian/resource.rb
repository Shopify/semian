module Semian
  class Resource #:nodoc:
    attr_reader :tickets, :name

    class << Semian::Resource
      # Ensure that there can only be one resource of a given type
      def instance(*args)
        Semian.resources[args.first] ||= new(*args)
      end
    end

    def initialize(name, tickets: nil, quota: nil, quota_min_tickets: 2, permissions: 0660, timeout: 0)
      if Semian.semaphores_enabled?
        initialize_semaphore(name, tickets, quota, quota_min_tickets, permissions, timeout) if respond_to?(:initialize_semaphore)
      else
        Semian.issue_disabled_semaphores_warning
      end
      @name = name
    end

    def destroy
    end

    def unregister_worker
    end

    def acquire(*)
      yield self
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
  end
end
