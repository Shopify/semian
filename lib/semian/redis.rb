require 'semian'
require 'semian/adapter'
require 'redis'

class Redis
  Redis::BaseConnectionError.class_exec { attr_accessor :semian_identifier }

  class SemianError < Redis::BaseConnectionError
    include ::Semian::AdapterError
  end

  ResourceBusyError = Class.new(SemianError)
  CircuitOpenError = Class.new(SemianError)

  # This memoized alias is necessary because during a `pipelined` block
  # the client is replaced by an instance of `Redis::Pipeline` and there is
  # no way to access the original client.
  def semian_resource
    @semian_resource ||= @client.semian_resource
  end

  def semian_identifier
    semian_resource.name
  end
end

module Semian
  module Redis
    include Semian::Adapter

    ResourceBusyError = ::Redis::ResourceBusyError
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
        name = semian_options && semian_options[:name]
        name ||= "#{location}/#{db}"
        :"redis_#{name}"
      end
    end

    def io(&block)
      acquire_semian_resource(adapter: :redis, scope: :query) { raw_io(&block) }
    end

    def connect
      acquire_semian_resource(adapter: :redis, scope: :connection) { raw_connect }
    end

    private

    def resource_exceptions
      [::Redis::BaseConnectionError]
    end

    def raw_semian_options
      return options[:semian] if options.key?(:semian)
      return options['semian'.freeze] if options.key?('semian'.freeze)
    end
  end
end

::Redis::Client.include(Semian::Redis)
