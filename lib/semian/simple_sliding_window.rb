# frozen_string_literal: true

require "thread"
require "concurrent"

module Semian
  module Simple
    class SlidingWindow # :nodoc:
      extend Forwardable

      def_delegators :@window, :size, :last, :empty?
      attr_reader :max_size

      # A sliding window is a structure that stores the most @max_size recent timestamps
      # like this: if @max_size = 4, current time is 10, @window =[5,7,9,10].
      # Another push of (11) at 11 sec would make @window [7,9,10,11], shifting off 5.

      def initialize(max_size:)
        @max_size = max_size
        @window = []
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
    class SlidingWindow
      extend Forwardable

      attr_reader :max_size

      def initialize(max_size:)
        @max_size = max_size
        @window_atom = Concurrent::Atom.new([])
      end

      def size
        @window_atom.value.size
      end

      def last
        @window_atom.value.last
      end

      def empty?
        @window_atom.value.empty?
      end

      def reject!(&block)
        @window_atom.swap do |window|
          window.reject(&block)
        end
        self
      end

      def push(value)
        @window_atom.swap do |window|
          new_window = window.dup
          new_window = resize_to(new_window, @max_size - 1) # make room
          new_window << value
          new_window
        end
        self
      end
      alias_method :<<, :push

      def clear
        @window_atom.reset([])
        self
      end
      alias_method :destroy, :clear

      private

      def resize_to(window, size)
        window.size >= size ? window.last(size) : window
      end
    end
  end
end
