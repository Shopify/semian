# frozen_string_literal: true

require "semian/adapter"
require "redis"

if Redis::VERSION >= "5"
  gem "redis", ">= 5.0.7"
  gem "redis-client", ">= 0.19.0"
  require "semian/redis/v5"
  return
end

class Redis
  Redis::BaseConnectionError.include(::Semian::AdapterError)
  ::Errno::EINVAL.include(::Semian::AdapterError)

  class SemianError < Redis::BaseConnectionError
    def initialize(semian_identifier, *args)
      super(*args)
      @semian_identifier = semian_identifier
    end
  end

  class OutOfMemoryError < Redis::CommandError
    include ::Semian::AdapterError
  end

  class ConnectionError < Redis::BaseConnectionError
    # A Connection Reset is a fast failure and we don't want to track these errors in
    # semian
    def marks_semian_circuits?
      message != "Connection lost (ECONNRESET)"
    end
  end

  class ReadOnlyError < Redis::CommandError
    # A ReadOnlyError is a fast failure and we don't want to track these errors so that we can reconnect
    # to the new primary ASAP
    def marks_semian_circuits?
      false
    end
  end

  ResourceBusyError = Class.new(SemianError)
  CircuitOpenError = Class.new(SemianError)
  ResolveError = Class.new(SemianError)

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
  unless instance_methods.include?(:_client)
    def _client
      @client
    end
  end
end

module Semian
  module RedisV4
    include Semian::Adapter

    ResourceBusyError = ::Redis::ResourceBusyError
    CircuitOpenError = ::Redis::CircuitOpenError
    ResolveError = ::Redis::ResolveError

    class << self
      # The naked methods are exposed as `raw_query` and `raw_connect` for instrumentation purpose
      def included(base)
        base.send(:alias_method, :raw_io, :io)
        base.send(:remove_method, :io)

        base.send(:alias_method, :raw_connect, :connect)
        base.send(:remove_method, :connect)
      end
    end

    def semian_identifier
      @semian_identifier ||= begin
        name = semian_options && semian_options[:name]
        name ||= "#{location}/#{db}"
        :"redis_#{name}"
      end
    end

    def io(&block)
      acquire_semian_resource(adapter: :redis, scope: :query) do
        reply = raw_io(&block)
        raise_if_out_of_memory(reply)
        reply
      end
    end

    def connect
      acquire_semian_resource(adapter: :redis, scope: :connection) do
        raw_connect
      rescue SocketError, RuntimeError => e
        raise ResolveError, semian_identifier if dns_resolve_failure?(e.cause || e)

        raise
      end
    end

    def with_resource_timeout(temp_timeout)
      timeout = options[:timeout]
      connect_timeout = options[:connect_timeout]
      read_timeout = options[:read_timeout]
      write_timeout = options[:write_timeout]

      begin
        connection.timeout = temp_timeout if connected?
        options[:timeout] = Float(temp_timeout)
        options[:connect_timeout] = Float(temp_timeout)
        options[:read_timeout] = Float(temp_timeout)
        options[:write_timeout] = Float(temp_timeout)
        yield
      ensure
        options[:timeout] = timeout
        options[:connect_timeout] = connect_timeout
        options[:read_timeout] = read_timeout
        options[:write_timeout] = write_timeout
        connection.timeout = self.timeout if connected?
      end
    end

    private

    def resource_exceptions
      [
        ::Redis::BaseConnectionError,
        ::Errno::EINVAL, # Hiredis bug: https://github.com/redis/hiredis-rb/issues/21
        ::Redis::OutOfMemoryError,
      ]
    end

    def raw_semian_options
      return options[:semian] if options.key?(:semian)
      return options["semian"] if options.key?("semian")
    end

    def raise_if_out_of_memory(reply)
      return unless reply.is_a?(::Redis::CommandError)
      return unless reply.message =~ /OOM command not allowed when used memory > 'maxmemory'/

      raise ::Redis::OutOfMemoryError, reply.message
    end

    def dns_resolve_failure?(e)
      e.to_s.match?(/(can't resolve)|(name or service not known)|(nodename nor servname provided, or not known)|(failure in name resolution)/i) # rubocop:disable Layout/LineLength
    end
  end
end

::Redis::Client.include(Semian::RedisV4)
