require 'thread'

module Semian
  module Simple
    class SlidingWindow #:nodoc:
      attr_reader :max_size

      # A sliding window is a structure that stores the most @max_size recent timestamps
      # like this: if @max_size = 4, current time is 10, @window =[5,7,9,10].
      # Another push of (11) at 11 sec would make @window [7,9,10,11], shifting off 5.

      def initialize(name, max_size:)
        initialize_sliding_window(name, max_size)
        @max_size = max_size
        @window = []
      end

      def size
        @window.size
      end

      def last
        @window.last
      end

      def values
        @window
      end

      def reject!(&block)
        @window.reject!(&block)
      end

      def push(value)
        resize_to(@max_size - 1) # make room
        @window << value
        self
      end
      alias_method :<<, :push

      def clear
        @window.clear
        self
      end
      alias_method :destroy, :clear

      private

      def resize_to(size)
        @window = @window.last(size) if @window.size >= size
      end
    end
  end

  module ThreadSafe
    class SlidingWindow < Simple::SlidingWindow
      def initialize(*)
        super
        @lock = Mutex.new
      end

      # #size, #last, and #clear are not wrapped in a mutex. For the first two,
      # the worst-case is a thread-switch at a timing where they'd receive an
      # out-of-date value--which could happen with a mutex as well.
      #
      # As for clear, it's an all or nothing operation. Doesn't matter if we
      # have the lock or not.

      def reject!(*)
        @lock.synchronize { super }
      end

      def push(*)
        @lock.synchronize { super }
      end
    end
  end
end
