# frozen_string_literal: true

require "semian/adapter"
require "active_record/connection_adapters/abstract_adapter"

module ActiveRecord
  module ConnectionAdapters
    class ActiveRecordAdapter
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
  module ActiveRecordAdapter
    include Semian::Adapter

    attr_reader :raw_semian_options, :semian_identifier

    def initialize(*options)
      *, config = options
      @read_timeout = config[:read_timeout] || 0
      @raw_semian_options = config.delete(:semian)
      @semian_identifier = begin
        name = semian_options && semian_options[:name]
        unless name
          host = config[:host] || "localhost"
          port = config[:port] || 3306
          name = "#{host}:#{port}"
        end
        :"activerecord_adapter_#{name}"
      end
      super
    end

    def execute(sql, name = nil, async: false, allow_retry: false)
      if query_allowlisted?(sql)
        super(sql, name, async: async, allow_retry: allow_retry)
      else
        acquire_semian_resource(adapter: :activerecord_adapter, scope: :execute) do
          super(sql, name, async: async, allow_retry: allow_retry)
        end
      end
    end

    def with_resource_timeout(temp_timeout)
      connection_was_nil = false

      if connection.nil?
        prev_read_timeout = @read_timeout # Use read_timeout from when we first connected
        connection_was_nil = true
      else
        prev_read_timeout = connection.read_timeout
        connection.read_timeout = temp_timeout
      end

      yield

      connection.read_timeout = temp_timeout if connection_was_nil
    ensure
      connection&.read_timeout = prev_read_timeout
    end

    private

    # AR adapter translates some of the raw connection errors, so we need special handling for the different adapters
    def acquire_semian_resource(**)
      super
    rescue ActiveRecord::StatementInvalid => error
      # if error.cause.is_a?(Trilogy::TimeoutError)
      #   semian_resource.mark_failed(error)
      #   error.semian_identifier = semian_identifier
      # end
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
      acquire_semian_resource(adapter: :activerecord_adapter, scope: :connection) do
        super
      end
    end

    def exceptions_to_handle
      [Trilogy::TimeoutError]
    end
  end
end

ActiveRecord::ConnectionAdapters::AbstractAdapter.prepend(Semian::TrilogyAdapter)
