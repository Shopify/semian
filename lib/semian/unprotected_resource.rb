module Semian
  # This class acts as a replacement for `ProtectedResource` when
  # the semian configuration of an `Adapter` is missing or explicitly disabled
  class UnprotectedResource
    attr_reader :name
    attr_accessor :updated_at

    def initialize(name)
      @name = name
      @updated_at = Time.now
    end

    def registered_workers
      0
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

    def size
      0
    end

    def max_size
      0
    end

    def values
      []
    end

    def semid
      0
    end

    def reset
    end

    def open?
      false
    end

    def closed?
      true
    end

    def half_open?
      false
    end

    def request_allowed?
      true
    end

    def mark_failed(_error)
    end

    def mark_success
    end

    def bulkhead
      nil
    end

    def circuit_breaker
      nil
    end

    def in_use?
      true
    end
  end
end
