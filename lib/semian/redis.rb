require 'semian'
require 'semian/adapter'
require 'redis'

::Redis::BaseConnectionError.include(::Semian::AdapterError)
::Errno::EINVAL.include(::Semian::AdapterError)

class Redis::SemianError < Redis::BaseConnectionError
  def initialize(semian_identifier, *args)
    super(*args)
    @semian_identifier = semian_identifier
  end
end

::Redis::ResourceBusyError = Class.new(::Redis::SemianError)
::Redis::CircuitOpenError = Class.new(::Redis::SemianError)

module Semian
  module Redis
    attr_reader :semian_resource

    def initialize(*)
      super

      # This alias is necessary because during a `pipelined` block
      # the client is replaced by an instance of `Redis::Pipeline` and there is
      # no way to access the original client.
      @semian_resource = client.semian_resource
    end

    def semian_identifier
      semian_resource.name
    end
  end

  module RedisClient
    include Semian::Adapter

    ResourceBusyError = ::Redis::ResourceBusyError
    CircuitOpenError = ::Redis::CircuitOpenError

    # The naked methods are exposed as `raw_query` and `raw_connect` for instrumentation purpose
    def self.prepended(base)
      base.send(:alias_method, :raw_io, :io)
      base.send(:alias_method, :raw_connect, :connect)
    end

    def semian_identifier
      @semian_identifier ||= begin
        name = semian_options && semian_options[:name]
        name ||= "#{location}/#{db}"
        :"redis_#{name}"
      end
    end

    def io
      acquire_semian_resource(adapter: :redis, scope: :query) { super }
    end

    def connect
      acquire_semian_resource(adapter: :redis, scope: :connection) { super }
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

::Redis.prepend(Semian::Redis)
::Redis::Client.prepend(Semian::RedisClient)
