# frozen_string_literal: true

module Semian
  module Simple
    # Counts successes and failures over a trailing window, one bucket per second.
    # The window covers between `window - 1` and `window` seconds of history.
    class TimeBucketedCounter # :nodoc:
      def initialize(window:)
        @size = window.ceil
        clear
      end

      def record_success
        @successes[current_bucket] += 1
      end

      def record_failure
        @failures[current_bucket] += 1
      end

      def counts
        advance
        successes = failures = 0
        @size.times do |bucket|
          next unless @epochs[bucket] && @epochs[bucket] > @epoch - @size

          successes += @successes[bucket]
          failures += @failures[bucket]
        end
        [successes, failures]
      end

      # Clears after running the block; a thread-safe counter records nothing in between.
      def clear
        yield if block_given?
        @epochs = Array.new(@size)
        @successes = Array.new(@size, 0)
        @failures = Array.new(@size, 0)
        @epoch = current_second
        self
      end

      def synchronize
        yield
      end

      def destroy
        clear
      end

      private

      def current_bucket
        advance
        bucket = @epoch % @size
        if @epochs[bucket] != @epoch
          @epochs[bucket] = @epoch
          @successes[bucket] = @failures[bucket] = 0
        end
        bucket
      end

      def advance
        now = current_second
        @epoch = now if now > @epoch
      end

      def current_second
        Process.clock_gettime(Process::CLOCK_MONOTONIC).to_i
      end
    end
  end

  module ThreadSafe
    class TimeBucketedCounter < Simple::TimeBucketedCounter
      def initialize(**)
        @lock = Mutex.new
        super
      end

      def record_success
        @lock.synchronize { super }
      end

      def record_failure
        @lock.synchronize { super }
      end

      def counts
        @lock.synchronize { super }
      end

      def clear(&block)
        @lock.synchronize { super }
      end

      def synchronize(&block)
        @lock.synchronize(&block)
      end
    end
  end
end
