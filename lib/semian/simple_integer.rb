require 'thread'

module Semian
  module Simple
    class Integer #:nodoc:
      attr_accessor :value
      alias_method :size, :value

      def initialize
        reset
      end

      def increment(val = 1)
        @value += val
      end

      def reset
        @value = 0
      end
      alias_method :clear, :reset

      def destroy
        reset
      end
    end
  end

  module ThreadSafe
    class Integer < Simple::Integer
      def initialize(*)
        super
        @lock = Mutex.new
      end

      def increment(*)
        @lock.synchronize { super }
      end
    end
  end
end
