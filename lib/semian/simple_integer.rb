# frozen_string_literal: true

require "thread"
require "concurrent"

module Semian
  module Simple
    class Integer # :nodoc:
      attr_accessor :value

      def initialize
        reset
      end

      def increment(val = 1)
        @value += val
      end

      def reset
        @value = 0
      end

      def destroy
        reset
      end
    end
  end

  module ThreadSafe
    class Integer
      def initialize
        @atom = Concurrent::Atom.new(0)
      end

      def value
        @atom.value
      end

      def value=(new_value)
        @atom.reset(new_value)
      end

      def increment(val = 1)
        @atom.swap { |current| current + val }
      end

      def reset
        @atom.reset(0)
      end

      def destroy
        reset
      end
    end
  end
end
