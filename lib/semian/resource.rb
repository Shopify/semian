module Semian
  class Resource #:nodoc:
    attr_reader :tickets, :name

    def initialize(name, tickets: , permissions: 0660, timeout: 0)
      _initialize(name, tickets, permissions, timeout) if respond_to?(:_initialize)
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
