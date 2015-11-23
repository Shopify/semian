module Semian
  module SysV
    class Integer < Semian::Simple::Integer #:nodoc:
      include SysVSharedMemory

      def initialize(name:, permissions:)
        data_layout = [:int]
        super() unless acquire_memory_object(name, data_layout, permissions)
      end
    end
  end
end
