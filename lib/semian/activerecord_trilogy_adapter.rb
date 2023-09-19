# frozen_string_literal: true

require "semian/adapter"
require "active_record"
require "active_record/connection_adapters/trilogy_adapter"

module ActiveRecord
  module ConnectionAdapters
    class TrilogyAdapter
      ActiveRecord::ActiveRecordError.include(::Semian::AdapterError)

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
  module ActiveRecordTrilogyAdapter
    include Semian::Adapter

    ResourceBusyError = ::ActiveRecord::ConnectionAdapters::TrilogyAdapter::ResourceBusyError
    CircuitOpenError = ::ActiveRecord::ConnectionAdapters::TrilogyAdapter::CircuitOpenError

    attr_reader :raw_semian_options, :semian_identifier

    def initialize(*options)
      *, config = options
      config = config.dup
      @raw_semian_options = config.delete(:semian)
      @semian_identifier = begin
        name = semian_options && semian_options[:name]
        unless name
          host = config[:host] || "localhost"
          port = config[:port] || 3306
          name = "#{host}:#{port}"
        end
        :"mysql_#{name}"
      end
      super
    end

    def raw_execute(sql, *)
      if query_allowlisted?(sql)
        super
      else
        acquire_semian_resource(adapter: :trilogy_adapter, scope: :query) do
          super
        end
      end
    end
    ruby2_keywords :raw_execute

    def active?
      p [:Trilogy_semian_active?]
      p STDERR
      acquire_semian_resource(adapter: :trilogy_adapter, scope: :ping) do
        super
      end
    rescue ResourceBusyError, CircuitOpenError
      false
    end

    def acquire_semian_resource(scope:, adapter:, &block)
      return yield if resource_already_acquired?

      p [:Trilogy_semian_acquire_semian_resource]
      p semian_resource
      p STDERR

      semian_resource.acquire(scope: scope, adapter: adapter, resource: self) do
        mark_resource_as_acquired(&block)
      end
    rescue ::Semian::OpenCircuitError => error
      last_error = semian_resource.circuit_breaker.last_error
      message = "#{error.message} caused by #{last_error.message}"
      last_error = nil unless last_error.is_a?(Exception) # Net::HTTPServerError is not an exception
      raise self.class::CircuitOpenError.new(semian_identifier, message), cause: last_error
    rescue ::Semian::BaseError => error
      raise self.class::ResourceBusyError.new(semian_identifier, error.message)
    rescue *resource_exceptions => error
      error.semian_identifier = semian_identifier if error.respond_to?(:semian_identifier=)
      raise
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

    def resource_exceptions
      [
        ActiveRecord::AdapterTimeout,
        ActiveRecord::ConnectionFailed,
        ActiveRecord::ConnectionNotEstablished,
      ]
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

ActiveRecord::ConnectionAdapters::TrilogyAdapter.prepend(Semian::ActiveRecordTrilogyAdapter)
