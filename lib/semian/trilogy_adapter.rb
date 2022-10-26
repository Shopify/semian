# frozen_string_literal: true

require "semian/adapter"
require "activerecord-trilogy-adapter"
require "active_record/connection_adapters/trilogy_adapter"

module ActiveRecord
  module ConnectionAdapters
    class TrilogyAdapter
      StatementInvalid.include(::Semian::AdapterError)

      class SemianError < StatementInvalid
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
  module TrilogyAdapter
    include Semian::Adapter

    attr_reader :raw_semian_options, :semian_identifier

    def initialize(options)
      @raw_semian_options = options.delete(:semian)
      @semian_identifier = begin
        name = semian_options && semian_options[:name]
        unless name
          host = options[:host] || "localhost"
          port = options[:port] || 3306
          name = "#{host}:#{port}"
        end
        :"trilogy_adapter_#{name}"
      end
      super
    end

    def execute(sql, *)
      if query_allowlisted?(sql)
        super
      else
        acquire_semian_resource(adapter: :trilogy_adapter, scope: :execute) do
          super
        end
      end
    end

    private

    def resource_exceptions
      []
    end

    # TODO: share this with Mysql2
    QUERY_ALLOWLIST = Regexp.union(
      %r{\A(?:/\*.*?\*/)?\s*ROLLBACK}i,
      %r{\A(?:/\*.*?\*/)?\s*COMMIT}i,
      %r{\A(?:/\*.*?\*/)?\s*RELEASE\s+SAVEPOINT}i,
    )

    def query_allowlisted?(sql, *)
      QUERY_ALLOWLIST.match?(sql)
    rescue ArgumentError
      return false unless sql.valid_encoding?

      raise
    end

    def connect(*args)
      acquire_semian_resource(adapter: :trilogy_adapter, scope: :connection) do
        super
      end
    end
  end
end

ActiveRecord::ConnectionAdapters::TrilogyAdapter.prepend(Semian::TrilogyAdapter)
