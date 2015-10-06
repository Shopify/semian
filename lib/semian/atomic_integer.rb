module Semian
  class AtomicInteger < SharedMemoryObject #:nodoc:

    def initialize(name, permissions)
      data_layout = [:int]
      if acquire(name, data_layout, permissions)
      else
        @value=0
      end
    end

    def value
      @value
    end

    def value=(val)
      @value=val
    end

    def increase_by(val)
      @value += val
      @value
    end

  end
end
