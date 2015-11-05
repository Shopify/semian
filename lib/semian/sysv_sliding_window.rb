module Semian
  class SysVSlidingWindow < SlidingWindow #:nodoc:
    def initialize(name, max_size, permissions)
      data_layout = [:int, :int].concat(Array.new(max_size, :long))
      super unless acquire_memory_object(name, data_layout, permissions)
    end
  end
end
