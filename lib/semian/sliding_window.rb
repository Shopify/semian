module Semian
  class SlidingWindow < SharedMemoryObject #:nodoc:
    extend Forwardable

    def_delegators :@window, :size, :pop, :shift, :first, :last
    attr_reader :max_size

    def initialize(_name, max_size, _permissions)
      @max_size = max_size
      @window = []
    end

    # A sliding window is a structure that stores the most @max_size recent timestamps
    # like this: if @max_size = 4, current time is 10, @window =[5,7,9,10].
    # Another push of (11) at 11 sec would make @window [7,9,10,11], shifting off 5.

    def resize_to(size)
      throw ArgumentError.new('size must be larger than 0') if size < 1
      @max_size = size
      @window.shift while @window.size > @max_size
      self
    end

    def <<(time_ms)
      push(time_ms)
    end

    def push(time_ms)
      @window.shift while @window.size >= @max_size
      @window << time_ms
      self
    end

    def unshift(time_ms)
      @window.pop while @window.size >= @max_size
      @window.unshift(time_ms)
      self
    end

    def clear
      @window = []
    end
  end

  class SysVSlidingWindow < SlidingWindow #:nodoc:
    def initialize(name, max_size, permissions)
      data_layout = [:int, :int].concat(Array.new(max_size, :long))
      super unless acquire_memory_object(name, data_layout, permissions)
    end
  end
end
