require 'forwardable'

module Semian
  module SysV
    class State < Semian::Simple::State #:nodoc:
      include SysVSharedMemory
      extend Forwardable

      def_delegators :@integer, :semid, :shmid, :synchronize, :transaction,
                     :shared?, :acquire_memory_object, :bind_init_fn
      private :shared?, :acquire_memory_object, :bind_init_fn

      def initialize(name:, permissions:)
        @integer = Semian::SysV::Integer.new(name: name, permissions: permissions)
        initialize_lookup([:closed, :open, :half_open])
      end

      def open
        self.value = :open
      end

      def close
        self.value = :closed
      end

      def half_open
        self.value = :half_open
      end

      def reset
        close
      end

      def destroy
        reset
        @integer.destroy
      end

      def value
        @num_to_sym.fetch(@integer.value) { raise ArgumentError }
      end

      private

      def value=(sym)
        @integer.value = @sym_to_num.fetch(sym) { raise ArgumentError }
      end

      def initialize_lookup(symbol_list)
        # Assume symbol_list[0] is mapped to 0
        # Cannot just use #object_id since #object_id for symbols is different in every run
        # For now, implement a C-style enum type backed by integers

        @sym_to_num = Hash[symbol_list.each_with_index.to_a]
        @num_to_sym = @sym_to_num.invert
      end
    end
  end
end
