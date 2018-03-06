require 'semian/adapter'
require 'redis'

class Redis
  Redis::BaseConnectionError.include(::Semian::AdapterError)
  ::Errno::EINVAL.include(::Semian::AdapterError)

  class SemianError < Redis::BaseConnectionError
    def initialize(semian_identifier, *args)
      super(*args)
      @semian_identifier = semian_identifier
    end
  end

  ResourceBusyError = Class.new(SemianError)
  CircuitOpenError = Class.new(SemianError)

  alias_method :_original_initialize, :initialize

  def initialize(*args, &block)
    _original_initialize(*args, &block)

    # This reference is necessary because during a `pipelined` block the client
    # is replaced by an instance of `Redis::Pipeline` and there is no way to
    # access the original client which references the Semian resource.
    @original_client = _client
  end

  def semian_resource
    @original_client.semian_resource
  end

  def semian_identifier
    semian_resource.name
  end

  # Compatibility with old versions of the Redis gem
  unless respond_to?(:_client)
    def _client
      @client
    end
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
      [
        ::Redis::BaseConnectionError,
        ::Errno::EINVAL, # Hiredis bug: https://github.com/redis/hiredis-rb/issues/21
      ]
    end

    def raw_semian_options
      return options[:semian] if options.key?(:semian)
      return options['semian'.freeze] if options.key?('semian'.freeze)
    end
  end
end

::Redis::Client.include(Semian::Redis)
