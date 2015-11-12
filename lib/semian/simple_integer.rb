module Semian
  module Simple
    class Integer < SharedMemoryObject #:nodoc:
      attr_accessor :value

      def initialize
        @value = 0
      end

      def increment(val = 1)
        @value += val
      end

      def reset
        @value = 0
      end

      def destroy
        if shared?
          super
        else
          @value = 0
        end
      end
    end
  end
end
