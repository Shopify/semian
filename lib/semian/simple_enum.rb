module Semian
  module Simple
    class Enum #:nodoc:
      def initialize(symbol_list:)
        @allowed_symbols = symbol_list
        reset
      end

      attr_reader :value

      def value=(sym)
        raise ArgumentError unless @allowed_symbols.include?(sym)
        @value = sym
      end

      def increment(val = 1)
        @value = @allowed_symbols[(@allowed_symbols.index(@value) + val) % @allowed_symbols.size]
      end

      def reset
        @value = @allowed_symbols.first
      end

      def destroy
        reset
      end
    end
  end
end
