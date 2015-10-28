module Semian
  class AtomicEnum < AtomicInteger #:nodoc:
    undef :increment_by
    undef :increment

    module AtomicEnumSharedImplementation
      def initialize(name, permissions, symbol_list)
        super(name, permissions)
        initialize_lookup(symbol_list)
      end

      def value
        @num_to_sym.fetch(super)
      end

      def value=(sym)
        super(@sym_to_num.fetch(sym))
      end

      private

      def initialize_lookup(symbol_list)
        # Assume symbol_list[0] is mapped to 0
        # Cannot just use #object_id since #object_id for symbols is different in every run
        # For now, implement a C-style enum type backed by integers

        @sym_to_num = {}
        symbol_list.each.with_index do |sym, idx|
          @sym_to_num[sym] = idx
        end
        @num_to_sym = @sym_to_num.invert
      end
    end

    include AtomicEnumSharedImplementation
  end
end
