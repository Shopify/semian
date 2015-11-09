module Semian
  class AtomicInteger #:nodoc:
    attr_accessor :value

    def initialize(**_options)
      @value = 0
    end

    def increment(val = 1)
      @value += val
    end

    def execute_atomically
      yield if block_given?
    end

    alias_method :transaction, :execute_atomically

    def destroy
      @value = 0
    end

    private

    def shared?
      false
    end
  end
end
