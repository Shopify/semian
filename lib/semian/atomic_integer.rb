module Semian
  class AtomicInteger < SharedMemoryObject #:nodoc:
    attr_accessor :value

    def initialize(_name, _permissions)
      @value = 0
    end

    def increment(val = 1)
      @value += val
    end
  end
end
