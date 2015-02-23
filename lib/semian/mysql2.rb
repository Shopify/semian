require 'semian'
require 'semian/adapter'
require 'mysql2'

module Mysql2
  Mysql2::Error.class_exec { attr_accessor :semian_identifier }

  class SemianError < Mysql2::Error
    include ::Semian::AdapterError
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

    # The naked methods are exposed as `raw_query` and `raw_connect` for instrumentation purpose
    def self.included(base)
      base.send(:alias_method, :raw_query, :query)
      base.send(:remove_method, :query)

      base.send(:alias_method, :raw_connect, :connect)
      base.send(:remove_method, :connect)
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
      acquire_semian_resource(adapter: :mysql, scope: :query) { raw_query(*args) }
    end

    private

    def connect(*args)
      acquire_semian_resource(adapter: :mysql, scope: :connection) { raw_connect(*args) }
    end

    def acquire_semian_resource(*)
      super
    rescue ::Mysql2::Error => error
      if error.message =~ CONNECTION_ERROR
        semian_resource.mark_failed(error)
      end
      raise
    end

    def raw_semian_options
      return query_options[:semian] if query_options.key?(:semian)
      return query_options['semian'.freeze] if query_options.key?('semian'.freeze)
    end
  end
end

::Mysql2::Client.include(Semian::Mysql2)
