require "forwardable"

module Semian
  # SlidingTimeWindow is an implementation of a sliding window data structure
  # enforcing two constrains:
  #
  # 1. The difference between the first and last element must be less than or
  #    equal to `duration`.
  # 2. The number of elements must be less than or equal to `max_size`.
  #
  # These constraints are only enforced at write time.
  class SlidingTimeWindow
    extend Forwardable

    attr_reader :window
    attr_accessor :max_size, :duration

    def_delegators :window, :size, :last, :first, :clear

    # Initialized a sliding time window.
    #
    # +max_size+: Maximum number of elements to keep in the window.
    #
    # +duration+: The maximum difference between the first and last element.
    def initialize(max_size:, duration: nil)
      @max_size = max_size
      @duration = duration
      @window = []
    end

    # Push a timestamp to the sliding time window. This will enforce the size
    # and duration of the window by removing elements from the start of the
    # window.
    #
    # +time+: Timestamp to add to the sliding window.
    def push(item = Time.now)
      clean(item)
      window << item
    end
    alias_method :<<, :push

    # Clean the sliding time window.
    #
    # +new_end+: Timestamp marking the end of the window.
    def clean(new_end = Time.now)
      window.shift while first && duration && first + duration < new_end
      window.shift if window.size == max_size
    end
  end
end
