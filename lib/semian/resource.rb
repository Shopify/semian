module Semian
  class Resource #:nodoc:
    attr_reader :tickets, :name

    def initialize(name, tickets, permissions, timeout)
      _initialize(name, tickets, permissions, timeout)
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
