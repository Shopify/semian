# frozen_string_literal: true

require "thread"
require "concurrent"

module Semian
  module SlidingWindowBehavior
    extend Forwardable

    def_delegators :@window, :size, :last, :empty?
    attr_reader :max_size

    # A sliding window is a structure that stores the most @max_size recent timestamps
    # like this: if @max_size = 4, current time is 10, @window =[5,7,9,10].
    # Another push of (11) at 11 sec would make @window [7,9,10,11], shifting off 5.

    def reject!(&block)
      @window.reject!(&block)
      self
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

  module Simple
    class SlidingWindow # :nodoc:
      include SlidingWindowBehavior

      def initialize(max_size:)
        @max_size = max_size
        @window = []
      end
    end
  end

  module ThreadSafe
    class SlidingWindow
      include SlidingWindowBehavior

      def initialize(max_size:)
        @max_size = max_size
        @window = Concurrent::Array.new
      end
    end
  end
end
