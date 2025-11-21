# frozen_string_literal: true

require "semian/activerecord_adapter"
require "active_record/connection_adapters/postgresql_adapter"

module ActiveRecord
  module ConnectionAdapters
    class PostgreSQLAdapter
      ActiveRecord::ActiveRecordError.include(::Semian::AdapterError)

      class SemianError < ConnectionNotEstablished
        def initialize(semian_identifier, *args)
          super(*args)
          @semian_identifier = semian_identifier
        end
      end

      ResourceBusyError = Class.new(SemianError)
      CircuitOpenError = Class.new(SemianError)
    end
  end
end

module Semian
  module ActiveRecordPostgreSQLAdapter
    include Semian::Adapter
    include Semian::ActiveRecordAdapter

    class << self
      def prepended(base)
        base.extend(Semian::ActiveRecordAdapter::ClassMethods)
      end
    end

    def with_resource_timeout(_temp_timeout)
      # Resource timeouts aren't possible with PostgreSQL because there is no
      # IO level timeout configuration, so we just yield.
      yield
    end

    private

    def semian_adapter_name = :postgresql_adapter

    def semian_adapter_default_port = 5432

    def semian_adapter_identifier_prefix = :postgresql
  end
end

ActiveRecord::ConnectionAdapters::PostgreSQLAdapter.prepend(Semian::ActiveRecordPostgreSQLAdapter)
