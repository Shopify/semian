module Semian
  class SysVAtomicEnum < AtomicEnum #:nodoc:
    def initialize(name, permissions, symbol_list)
      @integer = Semian::SysVAtomicInteger.new(name, permissions)
      initialize_lookup(symbol_list)
    end
  end
end
