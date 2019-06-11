require 'thread'

module Semian
  module Simple
    class Integer #:nodoc:
      attr_accessor :value

      def initialize(name)
        @name = name
        initialize_simple_integer if respond_to?(:initialize_simple_integer)
        reset
      end

      def increment(val)
        @value += val
      end

      def reset
        @value = 0
      end

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
