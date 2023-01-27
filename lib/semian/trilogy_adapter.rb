# frozen_string_literal: true

require "semian/adapter"
require "activerecord-trilogy-adapter"
require "active_record/connection_adapters/trilogy_adapter"

module ActiveRecord
  module ConnectionAdapters
    class TrilogyAdapter
      ActiveRecord::ActiveRecordError.include(::Semian::AdapterError)

      class SemianError < ActiveRecordError
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

    def initialize(*options)
      *, config = options
      @raw_semian_options = config.delete(:semian)
      @semian_identifier = begin
        name = semian_options && semian_options[:name]
        unless name
          host = config[:host] || "localhost"
          port = config[:port] || 3306
          name = "#{host}:#{port}"
        end
        :"trilogy_adapter_#{name}"
      end
      super
    end

    def execute(sql, name = nil, async: false, allow_retry: false)
      if query_allowlisted?(sql)
        super(sql, name, async: async, allow_retry: allow_retry)
      else
        acquire_semian_resource(adapter: :trilogy_adapter, scope: :execute) do
          super(sql, name, async: async, allow_retry: allow_retry)
        end
      end
    end

    def with_resource_timeout(temp_timeout)
      if connection.nil?
        prev_read_timeout = @config[:read_timeout] || 0
        @config.merge!(read_timeout: temp_timeout) # Create new client with temp_timeout for read timeout
      else
        prev_read_timeout = connection.read_timeout
        connection.read_timeout = temp_timeout
      end
      yield
    ensure
      @config.merge!(read_timeout: prev_read_timeout)
      connection&.read_timeout = prev_read_timeout
    end

    private

    def acquire_semian_resource(**)
      super
    rescue ActiveRecord::StatementInvalid => error
      if error.cause.is_a?(Trilogy::TimeoutError)
        semian_resource.mark_failed(error)
        error.semian_identifier = semian_identifier
      end
      raise
     end

    def resource_exceptions
      [ActiveRecord::ConnectionNotEstablished]
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
