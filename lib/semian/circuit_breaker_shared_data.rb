module Semian
  class CircuitBreakerSharedData #:nodoc:
    def initialize(name, arr_max_size, permissions)
      _initialize(name, arr_max_size, permissions) if respond_to?(:_initialize)
    end

    # For anyone consulting this, the array stores floats. Use Time.at(_float_here_) to convert to time

    def successes
      0
    end

    def successes=(num)
      0
    end

    def semid
      0
    end

    def shmid
      0
    end

    def length
      0
    end

    def size
      0
    end

    def count
      0
    end

    def << (float)
      nil
    end

    def push(float)
      nil
    end

    def pop
      nil
    end

    def shift
      nil
    end

    def unshift (float)
      nil
    end

    def clear
      nil
    end

    def first
      nil
    end

    def last
      nil
    end

  end
end
