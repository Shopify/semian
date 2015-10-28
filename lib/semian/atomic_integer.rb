module Semian
  class AtomicInteger #:nodoc:
    attr_accessor :value

    def initialize(_name, _permissions)
      @value = 0
    end

    def increment_by(val)
      self.value += val
    end

    def increment
      increment_by(1)
    end

    def execute_atomically
      yield if block_given?
    end

    def shared?
      false
    end

    def destroy
    end
  end
end
