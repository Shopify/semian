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

    def execute(sql, name = nil, async: false)
      if query_allowlisted?(sql)
        super(sql, name, async: async)
      else
        acquire_semian_resource(adapter: :trilogy_adapter, scope: :execute) do
          super(sql, name, async: async)
        end
      end
    end

    def with_resource_timeout(temp_timeout)
      if connection.nil?
        prev_read_timeout = @config[:read_timeout] || 0 # We're assuming defaulting the timeout to 0 won't change in Trilogy
        @config[:read_timeout] = temp_timeout # Create new client with config
      else
        prev_read_timeout = connection.read_timeout
        connection.read_timeout = temp_timeout
      end
      yield
    ensure
      @config[:read_timeout] = prev_read_timeout
      connection&.read_timeout = prev_read_timeout
    end

    private

    def resource_exceptions
      []
    end

    def acquire_semian_resource(**)
      super
    # We're going to need to rescue ConnectionNotEstablished here
    # and fix this upstream in the Trilogy adapter -- right now, #new_client raises
    # raw ECONNREFUSED errors
    # Also, we shouldn't be wrapping TIMEDOUT and ECONNREFUSED in StatementInvalid => use
    # more appropriate error classes
    # We see ECONNREFUSED wrapped as an AR::StatementInvalid exception instead of the
    # raw one when we go through #execute, because it gets translated in #with_raw_connection
    # I think #new_client should just be more nuanced
    rescue ActiveRecord::StatementInvalid => error
      if error.cause.is_a?(Errno::ETIMEDOUT) || error.cause.is_a?(Errno::ECONNREFUSED)
        semian_resource.mark_failed(error)
        error.semian_identifier = semian_identifier
      end
      raise
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
