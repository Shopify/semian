module Semian
  # This class acts as a replacement for `ProtectedResource` when
  # the semian configuration of an `Adatper` is missing or explicitly disabled
  class UnprotectedResource
    attr_reader :name

    def initialize(name)
      @name = name
    end

    def tickets
      -1
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

    def reset
    end

    def request_allowed?
      true
    end

    def mark_failed(_error)
    end

    def mark_success
    end

    def circuit_breaker_shared?
      false
    end
  end
end
