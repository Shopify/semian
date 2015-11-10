module Semian
  class SysVSlidingWindow < SlidingWindow #:nodoc:
    def initialize(max_size, name:, permissions:)
      data_layout = [:int, :int].concat(Array.new(max_size, :long))
      super(max_size) unless acquire_memory_object(name, data_layout, permissions)
    end
  end
end
