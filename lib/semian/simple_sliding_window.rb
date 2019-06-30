require 'thread'

module Semian
  module Simple
    class SlidingWindow #:nodoc:
      # A sliding window is a structure that stores the most @max_size recent timestamps
      # like this: if @max_size = 4, current time is 10, @window =[5,7,9,10].
      # Another push of (11) at 11 sec would make @window [7,9,10,11], shifting off 5.

      def initialize(name, max_size:, scale_factor: nil)
        initialize_sliding_window(name, max_size, scale_factor) if respond_to?(:initialize_sliding_window)

        @name = name.to_sym
        @max_size = max_size
        @window = []
      end

      def use_host_circuits
        ENV['SEMIAN_CIRCUIT_BREAKER_IMPL'] == 'host'
      end

      def size
        raise StandardError, "Shouldn't call size if using host circuits" if use_host_circuits
        @window.size
      end

      def last
        raise StandardError, "Shouldn't call last if using host circuits" if use_host_circuits
        @window.last
      end

      def values
        raise StandardError, "Shouldn't call values if using host circuits" if use_host_circuits
        @window
      end

      def reject!(&block)
        raise StandardError, "Shouldn't call reject! if using host circuits" if use_host_circuits
        @window.reject!(&block)
      end

      def push(value)
        raise StandardError, "Shouldn't call push if using host circuits" if use_host_circuits
        resize_to(@max_size - 1) # make room
        @window << value
        self
      end
      alias_method :<<, :push

      def clear
        raise StandardError, "Shouldn't call clear if using host circuits" if use_host_circuits
        @window.clear
        self
      end
      alias_method :destroy, :clear

      def max_size
        raise StandardError, "Shouldn't call max_size if using host circuits" if use_host_circuits
        @max_size
      end

      def max_size=(value)
        raise StandardError, "Shouldn't call max_size= if using host circuits" if use_host_circuits
        raise ArgumentError, "max_size must be positive" if value <= 0
        @max_size = value
        resize_to(value)
      end

      private

      def resize_to(size)
        raise StandardError, "Shouldn't call resize_to if using host circuits" if use_host_circuits
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
