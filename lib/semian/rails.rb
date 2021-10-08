# frozen_string_literal: true

require "active_record/connection_adapters/abstract_adapter"

module ActiveRecord
  module ConnectionAdapters
    class AbstractAdapter
      def semian_resource
        @connection.semian_resource
      end
    end
  end
end
