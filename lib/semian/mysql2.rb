require 'semian'
require 'mysql2'

module Mysql2
  class SemianError < Mysql2::Error
    def initialize(semian_identifier, *args)
      super(*args)
      @semian_identifier = semian_identifier
    end

    def to_s
      "[#{@semian_identifier}] #{super}"
    end
  end

  ResourceOccupiedError = Class.new(SemianError)
  CircuitOpenError = Class.new(SemianError)
end

module Semian
  module Mysql2
    DEFAULT_HOST = 'localhost'
    DEFAULT_PORT = 3306

    def semian_identifier
      @semian_identifier ||= begin
        semian_options = query_options[:semian] || {}
        unless name = semian_options['name'.freeze] || semian_options[:name]
          host = query_options[:host] || DEFAULT_HOST
          port = query_options[:port] || DEFAULT_PORT
          name = "#{host}:#{port}"
        end
        :"mysql_#{name}"
      end
    end

    def query(*)
      semian_resource.acquire { super }
    rescue ::Semian::OpenCircuitError => error
      raise ::Mysql2::CircuitOpenError.new(semian_identifier, error)
    rescue ::Semian::BaseError => error
      raise ::Mysql2::ResourceOccupiedError.new(semian_identifier, error)
    end

    private

    def connect(*)
      semian_resource.acquire { super }
    rescue ::Semian::OpenCircuitError => error
      raise ::Mysql2::CircuitOpenError.new(semian_identifier, error)
    rescue ::Semian::BaseError => error
      raise ::Mysql2::ResourceOccupiedError.new(semian_identifier, error)
    end

    def semian_resource
      @semian_resource ||= ::Semian.retrieve_or_register(semian_identifier, **semian_options)
    end

    def semian_options
      options = query_options[:semian] || {}
      options = options.map { |k, v| [k.to_sym, v] }.to_h
      options.delete(:name)
      options
    end
  end
end

::Mysql2::Client.prepend(Semian::Mysql2)
