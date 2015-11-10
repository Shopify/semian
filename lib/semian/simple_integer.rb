module Semian
  module Simple
    class Integer #:nodoc:
      attr_accessor :value

      def initialize
        @value = 0
      end

      def increment(val = 1)
        @value += val
      end

      def destroy
        @value = 0
      end
    end
  end
end
