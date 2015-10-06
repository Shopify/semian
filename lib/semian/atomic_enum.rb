module Semian
  class AtomicEnum < AtomicInteger
    undef :increase_by

    def initialize(name, permissions, symbol_list)
      super(name, permissions)

      # Assume symbol_list[0] is mapped to 0
      # Cannot just use #object_id since #object_id for symbols are different for every run
      # For now, implement a C-style enum type backed by integers

      @sym_to_num = {}
      symbol_list.each.with_index do |sym,idx|
        @sym_to_num[sym]=idx
      end
      @num_to_sym = @sym_to_num.invert
    end

    def value
      @num_to_sym.fetch super # May raise KeyError if num is not in list (invalid enum)
    end

    def value=(sym)
      super (@sym_to_num.fetch(sym)) # May raise KeyError if sym is not in list (invalid enum)
    end

  end
end
