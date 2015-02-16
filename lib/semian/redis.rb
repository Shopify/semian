require 'semian'
require 'semian/adapter'
require 'redis'

class Redis
  class SemianError < Redis::BaseConnectionError
    include ::Semian::AdapterError
  end

  ResourceOccupiedError = Class.new(SemianError)
  CircuitOpenError = Class.new(SemianError)
end

module Semian
  module Redis
    include Semian::Adapter

    ResourceOccupiedError = ::Redis::ResourceOccupiedError
    CircuitOpenError = ::Redis::CircuitOpenError

    # The naked methods are exposed as `raw_query` and `raw_connect` for instrumentation purpose
    def self.included(base)
      base.send(:alias_method, :raw_io, :io)
      base.send(:remove_method, :io)

      base.send(:alias_method, :raw_connect, :connect)
      base.send(:remove_method, :connect)
    end

    def semian_identifier
      @semian_identifier ||= begin
        opts = options[:semian] || options['semian'.freeze] || {}
        name = opts[:name] || opts['name'.freeze]
        name ||= "#{location}/#{db}"
        :"redis_#{name}"
      end
    end

    def io(&block)
      acquire_semian_resource(scope: :query) { raw_io(&block) }
    end

    def connect
      acquire_semian_resource(scope: :connection) { raw_connect }
    end

    private

    def semian_options
      opts = options[:semian] || options['semian'.freeze] || {}
      opts = opts.map { |k, v| [k.to_sym, v] }.to_h
      opts.delete(:name)
      opts
    end
  end
end

::Redis::Client.include(Semian::Redis)
