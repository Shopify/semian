require 'forwardable'

module Semian
  class AtomicEnum #:nodoc:
    extend Forwardable

    def_delegators :@integer, :execute_atomically, :transaction, :shared?, :destroy
    private :shared?

    def initialize(symbol_list, **_options)
      @integer = Semian::AtomicInteger.new
      initialize_lookup(symbol_list)
    end

    def increment(val = 1)
      @integer.value = (@integer.value + val) % @sym_to_num.size
      value
    end

    def value
      @num_to_sym.fetch(@integer.value)
    end

    def value=(sym)
      @integer.value = @sym_to_num.fetch(sym)
    end

    private

    def initialize_lookup(symbol_list)
      # Assume symbol_list[0] is mapped to 0
      # Cannot just use #object_id since #object_id for symbols is different in every run
      # For now, implement a C-style enum type backed by integers

      @sym_to_num = Hash[symbol_list.each_with_index.to_a]
      @num_to_sym = @sym_to_num.invert
    end
  end
end
