require 'thread'

module Semian
  module Simple
    class TimeSlidingWindow #:nodoc:
      extend Forwardable

      def_delegators :@window, :size, :empty?, :length
      attr_reader :time_window_ms

      Pair = Struct.new(:head, :tail)

      # A sliding window is a structure that stores the most recent entries that were pushed within the last slice of time
      def initialize(time_window, time_source = nil)
        @time_window_ms = time_window * 1000
        @time_source = time_source ? time_source : -> { Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond) }
        @window = []
      end

      def count(&block)
        remove_old
        vals = @window.map(&:tail)
        vals.count(&block)
      end

      def each_with_object(memo, &block)
        remove_old
        vals = @window.map(&:tail)
        vals.each_with_object(memo, &block)
      end

      def push(value)
        remove_old # make room
        @window << Pair.new(current_time, value)
        self
      end

      alias_method :<<, :push

      def clear
        @window.clear
        self
      end

      def last
        @window.last&.tail
      end

      alias_method :destroy, :clear

      private

      def remove_old
        return if @window.empty?
        midtime = current_time - time_window_ms
        # special case, everything is too old
        @window.clear if @window.last.head < midtime
        # otherwise we find the index position where the cutoff is
        idx = (0...@window.size).bsearch { |n| @window[n].head >= midtime }
        @window.slice!(0, idx) if idx
      end

      def current_time
        @time_source.call
      end
    end
  end

  module ThreadSafe
    class TimeSlidingWindow < Simple::TimeSlidingWindow
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

      def count(*)
        @lock.synchronize { super }
      end

      def each_with_object(*)
        @lock.synchronize { super }
      end

      def push(*)
        @lock.synchronize { super }
      end
    end
  end
end
