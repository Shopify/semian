require 'thread'

module Semian
  module Simple
    class Integer #:nodoc:
      attr_accessor :value

      def initialize(name)
        initialize_simple_integer(name) if respond_to?(:initialize_simple_integer)
        reset
      end

      def use_host_circuits
        ENV['SEMIAN_CIRCUIT_BREAKER_IMPL'] == 'host'
      end

      def increment(val = 1)
        raise StandardError, "Shouldn't call increment if using host circuits" if use_host_circuits
        @value += val
      end

      def reset
        raise StandardError, "Shouldn't call reset if using host circuits" if use_host_circuits
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
