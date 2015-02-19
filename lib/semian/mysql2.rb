require 'semian'
require 'semian/adapter'
require 'mysql2'

module Mysql2
  class SemianError < Mysql2::Error
    include ::Semian::AdapterError
  end

  ResourceOccupiedError = Class.new(SemianError)
  CircuitOpenError = Class.new(SemianError)
end

module Semian
  module Mysql2
    include Semian::Adapter

    ResourceOccupiedError = ::Mysql2::ResourceOccupiedError
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
      acquire_semian_resource(scope: :query) { raw_query(*args) }
    end

    private

    def connect(*args)
      acquire_semian_resource(scope: :connection) { raw_connect(*args) }
    end

    def raw_semian_options
      return query_options[:semian] if query_options.key?(:semian)
      return query_options['semian'.freeze] if query_options.key?('semian'.freeze)
    end
  end
end

::Mysql2::Client.include(Semian::Mysql2)
