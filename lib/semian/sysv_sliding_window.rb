module Semian
  module SysV
    class SlidingWindow < Semian::Simple::SlidingWindow #:nodoc:
      include SysVSharedMemory

      def initialize(max_size:, name:, permissions:)
        acquire_memory_object(name, calculate_byte_size(max_size), permissions)
      end
    end
  end
end
