module Semian
  module Simple
    class State #:nodoc:
      extend Forwardable

      def_delegators :@value, :value

      # State constants. Looks like a flag, but is actually an enum.
      UNKNOWN   = 0x0
      CLOSED    = 0x1
      OPEN      = 0x2
      HALF_OPEN = 0x4

      def initialize(value)
        @value = value
        reset
      end

      def open?
        @value.value == OPEN
      end

      def closed?
        @value.value == CLOSED
      end

      def half_open?
        @value.value == HALF_OPEN
      end

      def open!
        @value.value = OPEN
      end

      def close!
        @value.value = CLOSED
      end

      def half_open!
        @value.value = HALF_OPEN
      end

      def reset
        close!
      end

      def destroy
        reset
      end

      def to_s
        case @value.value
        when UNKNOWN
          "unknown"
        when CLOSED
          "closed"
        when OPEN
          "open"
        when HALF_OPEN
          "half_open"
        else
          "<undefined>"
        end
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
