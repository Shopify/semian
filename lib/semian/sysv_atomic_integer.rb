module Semian
  class SysVAtomicInteger < AtomicInteger #:nodoc:
    def initialize(name:, permissions:)
      data_layout = [:int]
      super() unless acquire_memory_object(name, data_layout, permissions)
    end
  end
end
