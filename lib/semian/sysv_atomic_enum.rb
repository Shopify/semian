module Semian
  class SysVAtomicEnum < AtomicEnum #:nodoc:
    def initialize(symbol_list, name:, permissions:)
      @integer = Semian::SysVAtomicInteger.new(name: name, permissions: permissions)
      initialize_lookup(symbol_list)
    end
  end
end
