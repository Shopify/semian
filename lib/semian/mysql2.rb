require 'semian'
require 'semian/adapter'
require 'mysql2'

module Mysql2
  Mysql2::Error.include(::Semian::AdapterError)

  class SemianError < Mysql2::Error
    def initialize(semian_identifier, *args)
      super(*args)
      @semian_identifier = semian_identifier
    end
  end

  ResourceBusyError = Class.new(SemianError)
  CircuitOpenError = Class.new(SemianError)
end

module Semian
  module Mysql2
    include Semian::Adapter

    CONNECTION_ERROR = Regexp.union(
      /Can't connect to MySQL server on/i,
      /Lost connection to MySQL server during query/i,
      /MySQL server has gone away/i,
    )

    ResourceBusyError = ::Mysql2::ResourceBusyError
    CircuitOpenError = ::Mysql2::CircuitOpenError

    DEFAULT_HOST = 'localhost'
    DEFAULT_PORT = 3306

    QUERY_WHITELIST = Regexp.union(
      /\A\s*ROLLBACK/i,
      /\A\s*COMMIT/i,
      /\A\s*RELEASE\s+SAVEPOINT/i,
    )

    # The naked methods are exposed as `raw_query` and `raw_connect` for instrumentation purpose
    def self.prepended(base)
      base.send(:alias_method, :raw_query, :query)
      base.send(:alias_method, :raw_connect, :connect)
    end

    def semian_identifier
      @semian_identifier ||= begin
        unless name = semian_options && semian_options[:name]
          host = query_options[:host] || DEFAULT_HOST
          port = query_options[:port] || DEFAULT_PORT
          name = "#{host}:#{port}"
        end
        :"mysql_#{name}"
      end
    end

    def query(*args)
      if query_whitelisted?(*args)
        super
      else
        acquire_semian_resource(adapter: :mysql, scope: :query) { super }
      end
    end

    private

    def query_whitelisted?(sql, *)
      QUERY_WHITELIST =~ sql
    rescue ArgumentError
      # The above regexp match can fail if the input SQL string contains binary
      # data that is not recognized as a valid encoding, in which case we just
      # return false.
      return false unless sql.valid_encoding?
      raise
    end

    def connect(*args)
      acquire_semian_resource(adapter: :mysql, scope: :connection) { super }
    end

    def acquire_semian_resource(*)
      super
    rescue ::Mysql2::Error => error
      if error.message =~ CONNECTION_ERROR
        semian_resource.mark_failed(error)
        error.semian_identifier = semian_identifier
      end
      raise
    end

    def raw_semian_options
      return query_options[:semian] if query_options.key?(:semian)
      return query_options['semian'.freeze] if query_options.key?('semian'.freeze)
    end
  end
end

::Mysql2::Client.prepend(Semian::Mysql2)
