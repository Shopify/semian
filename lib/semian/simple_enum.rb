module Semian
  module Simple
    class Enum #:nodoc:
      attr_reader :value

      def initialize
        reset
      end

      def closed?
        value == :closed
      end

      def open?
        value == :open
      end

      def half_open?
        value == :half_open
      end

      def close
        @value = :closed
      end

      def open
        @value = :open
      end

      def half_open
        @value = :half_open
      end

      def reset
        close
      end

      def destroy
        close
      end
    end
  end
end
