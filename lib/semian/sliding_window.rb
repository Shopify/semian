module Semian
  class SlidingWindow #:nodoc:
    def initialize(name, max_window_size, permissions)
      if respond_to?(:_initialize)
        _initialize(name, max_window_size, permissions)
      else
        @successes = 0
        @max_window_size = max_window_size
        @window = []
      end
    end

    # For anyone consulting this, the array stores an integer amount of seconds since epoch
    # Use Time.at(_time_ms_ / 1000) to convert to time

    # A sliding window is a structure that keeps at most @max_window_size recent timestamps
    # in store, like this: if @max_window_size = 4, current time is 10, @window =[5,7,9,10].
    # Another push of (11) at 11 sec would make @window [7,9,10,11], popping off 5.

    def self.shared?
      false
    end

    def max_window_size
      @max_window_size
    end

    def successes
      @successes
    end

    def successes=(num)
      @successes=num
    end

    def semid
      -1
    end

    def shmid
      -1
    end

    def size
      @window.size
    end

    def << (time_ms)
      push(time_ms)
    end

    def push(time_ms)
      @window.shift while @window.size >= @max_window_size
      @window << time_ms
    end

    def pop
      @window.pop
    end

    def shift
      @window.shift
    end

    def unshift (time_ms)
      @window.pop while @window.size >= @max_window_size
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
