module Semian
  module SysV
    class Integer < Semian::Simple::Integer #:nodoc:
      include SysVSharedMemory

      def initialize(name:, permissions:)
        acquire_memory_object(name, calculate_byte_size, permissions)
      end
    end
  end
end
