module Semian
  module SysV
    class Enum < Semian::Simple::Enum #:nodoc:
      def initialize(symbol_list:, name:, permissions:)
        @integer = Semian::SysV::Integer.new(name: name, permissions: permissions)
        initialize_lookup(symbol_list)
      end
    end
  end
end
