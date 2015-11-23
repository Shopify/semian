require 'forwardable'

module Semian
  module SysV
    class State < Semian::Simple::State #:nodoc:
      include SysVSharedMemory
      extend Forwardable

      SYM_TO_NUM = {closed: 0, open: 1, half_open: 2}.freeze
      NUM_TO_SYM = SYM_TO_NUM.invert.freeze

      def_delegators :@integer, :semid, :shmid, :synchronize, :acquire_memory_object,
                     :bind_initialize_memory_callback, :destroy
      private :acquire_memory_object, :bind_initialize_memory_callback

      def initialize(name:, permissions:)
        @integer = Semian::SysV::Integer.new(name: name, permissions: permissions)
      end

      def value
        NUM_TO_SYM.fetch(@integer.value) { raise ArgumentError }
      end

      private

      def value=(sym)
        @integer.value = SYM_TO_NUM.fetch(sym) { raise ArgumentError }
      end
    end
  end
end
