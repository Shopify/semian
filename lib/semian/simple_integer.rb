module Semian
  module Simple
    class Integer #:nodoc:
      attr_accessor :value

      def initialize(**_)
        reset
      end

      def increment(val = 1)
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
end
