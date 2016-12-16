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

  attr_reader :semian_resource

  alias_method :_original_initialize, :initialize

  def initialize(*args, &block)
    _original_initialize(*args, &block)

    # This alias is necessary because during a `pipelined` block
    # the client is replaced by an instance of `Redis::Pipeline` and there is
    # no way to access the original client.
    @semian_resource = client.semian_resource
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

    def semian_identifier
      @semian_identifier ||= begin
        name = semian_options && semian_options[:name]
        name ||= "#{location}/#{db}"
        :"redis_#{name}"
      end
    end

    def io(*)
      acquire_semian_resource(adapter: :redis, scope: :query) { super }
    end

    def connect(*)
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

::Redis::Client.prepend(Semian::Redis)
