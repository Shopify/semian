# frozen_string_literal: true

module Semian
  class Resource # :nodoc:
    attr_reader :name

    class << Semian::Resource
      # Ensure that there can only be one resource of a given type
      def instance(name, **kwargs)
        Semian.resources[name] ||= ProtectedResource.new(name, new(name, **kwargs), nil)
      end
    end

    def initialize(name, tickets: nil, quota: nil, permissions: Semian.default_permissions, timeout: 0)
      unless name.is_a?(String) || name.is_a?(Symbol)
        raise TypeError, "name must be a string or symbol, got: #{name.class}"
      end

      if Semian.semaphores_enabled?
        if respond_to?(:initialize_semaphore)
          initialize_semaphore("#{Semian.namespace}#{name}", tickets, quota, permissions, timeout)
        end
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
      "0x00000000"
    end

    def in_use?
      false
    end
  end
end
