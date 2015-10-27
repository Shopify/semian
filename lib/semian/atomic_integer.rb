module Semian
  class AtomicInteger < SharedMemoryObject #:nodoc:
    attr_accessor :value

    def initialize(_name, _permissions)
      @value = 0
    end

    def increase_by(val)
      self.value += val
    end
  end

  class SysVAtomicInteger < AtomicInteger #:nodoc:
    def initialize(name, permissions)
      data_layout = [:int]
      super unless acquire_memory_object(name, data_layout, permissions)
    end
  end
end
