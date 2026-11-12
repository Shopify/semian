# frozen_string_literal: true

module Semian
  module Simple
    # Counts successes and failures over a trailing window, one bucket per second, oldest first.
    # The window covers between `window - 1` and `window` seconds of history.
    # Totals are kept next to the buckets, so recording and reading cost the same whatever the window.
    class TimeBucketedCounter # :nodoc:
      def initialize(window:)
        @size = window.ceil
        clear
      end

      def record_success
        advance
        @successes[-1] += 1
        @total_successes += 1
      end

      def record_failure
        advance
        @failures[-1] += 1
        @total_failures += 1
      end

      def counts
        advance
        [@total_successes, @total_failures]
      end

      # Clears after running the block; a thread-safe counter records nothing in between.
      def clear
        yield if block_given?
        @successes = Array.new(@size, 0)
        @failures = Array.new(@size, 0)
        @total_successes = @total_failures = 0
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

      # Once per second at most, the buckets that left the window become its newest, empty ones. That touches every
      # bucket, but in C and whatever the gap, so the first call after an idle period stays cheap. A clock that goes
      # backwards keeps recording into the newest bucket.
      def advance
        now = current_second
        return if now <= @epoch

        elapsed = [now - @epoch, @size].min
        @total_successes = @successes.rotate!(elapsed).fill(0, -elapsed).sum
        @total_failures = @failures.rotate!(elapsed).fill(0, -elapsed).sum
        @epoch = now
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
