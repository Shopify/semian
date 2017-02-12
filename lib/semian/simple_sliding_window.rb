module Semian
  module Simple
    class SlidingWindow #:nodoc:
      extend Forwardable

      def_delegators :@window, :size, :pop, :shift, :first, :last
      attr_reader :max_size

      # A sliding window is a structure that stores the most @max_size recent timestamps
      # like this: if @max_size = 4, current time is 10, @window =[5,7,9,10].
      # Another push of (11) at 11 sec would make @window [7,9,10,11], shifting off 5.

      def initialize(max_size:, **)
        @max_size = max_size
        @window = []
      end

      def resize_to(size)
        raise ArgumentError.new('size must be larger than 0') if size < 1
        @max_size = size
        @window.shift while @window.size > @max_size
        self
      end

      def push(value)
        @window.shift while @window.size >= @max_size
        @window << value
        self
      end

      alias_method :<<, :push

      def clear
        @window.clear
        self
      end

      def destroy
        clear
      end
    end
  end
end
