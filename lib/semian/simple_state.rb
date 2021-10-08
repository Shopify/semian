# frozen_string_literal: true

module Semian
  module Simple
    class State # :nodoc:
      def initialize
        reset
      end

      attr_reader :value

      def open?
        value == :open
      end

      def closed?
        value == :closed
      end

      def half_open?
        value == :half_open
      end

      def open!
        @value = :open
      end

      def close!
        @value = :closed
      end

      def half_open!
        @value = :half_open
      end

      def reset
        close!
      end

      def destroy
        reset
      end
    end
  end

  module ThreadSafe
    class State < Simple::State
      # These operations are already safe for a threaded environment since it's
      # a simple assignment.
    end
  end
end
