module Semian
  class SlidingWindow #:nodoc:
    def initialize(name, max_window_length, permissions)
      if respond_to?(:_initialize)
        _initialize(name, max_window_length, permissions)
      else
        @successes = 0
        @max_window_length = max_window_length
        @window = []
      end
    end

    # For anyone consulting this, the array stores an integer amount of seconds since epoch
    # Use Time.at(_time_ms_ / 1000) to convert to time
    def self.shared?
      false
    end

    def successes
      @successes
    end

    def successes=(num)
      @successes=num
    end

    def semid
      0
    end

    def shmid
      0
    end

    def size
      @window.size
    end

    def << (time_ms)
      push(time_ms)
    end

    def push(time_ms)
      @window.shift while @window.size >= @max_window_length
      @window << time_ms
    end

    def pop
      @window.pop
    end

    def shift
      @window.shift
    end

    def unshift (time_ms)
      @window.pop while @window.size >= @max_window_length
      @window.unshift(time_ms)
    end

    def clear
      @window = [];
    end

    def first
      @window.first
    end

    def last
      @window.last
    end

  end
end
