module Semian
  class Resource #:nodoc:
    attr_reader :tickets, :name

    def initialize(name, tickets:, quota: 0, permissions: 0660, timeout: 0)
      if Semian.semaphores_enabled?
        initialize_semaphore(name, tickets, quota, permissions, timeout) if respond_to?(:initialize_semaphore)
      else
        Semian.issue_disabled_semaphores_warning
      end
      @name = name
      @tickets = tickets
    end

    def destroy
    end

    def acquire(*)
      yield self
    end

    def count
      0
    end

    def semid
      0
    end
  end
end
