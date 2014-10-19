class Semian
  MAX_TICKETS = 0

  class Resource #:nodoc:
    def initialize(name, tickets, permissions, timeout); end

    def destroy; end

    def acquire
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
