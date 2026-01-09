# frozen_string_literal: true

require "semian/adapter"
require "redis-client"

class RedisClient
  ConnectionError.include(::Semian::AdapterError)
  ConnectionError.class_eval do
    # A Connection Reset is a fast failure and we don't want to track these errors in semian
    def marks_semian_circuits?
      !message.include?("Connection reset by peer")
    end
  end

  OutOfMemoryError.include(::Semian::AdapterError)
  OutOfMemoryError.class_eval do
    # OOM errors open circuits by default (backward compatible behavior).
    def marks_semian_circuits?
      true
    end
  end

  # A variant of OutOfMemoryError that does NOT open circuits.
  # Use this when you want reads/deletes to continue working when Redis is OOM,
  # allowing it to recover. Configure with `open_circuit_on_oom: false`.
  class RecoverableOutOfMemoryError < OutOfMemoryError
    include ::Semian::AdapterError

    def marks_semian_circuits?
      false
    end
  end

  class ReadOnlyError < RedisClient::ConnectionError
    # A ReadOnlyError is a fast failure and we don't want to track these errors so that we can reconnect
    # to the new primary ASAP
    def marks_semian_circuits?
      false
    end
  end

  class SemianError < ConnectionError
    def initialize(semian_identifier, *args)
      super(*args)
      @semian_identifier = semian_identifier
    end
  end

  ResourceBusyError = Class.new(SemianError)
  CircuitOpenError = Class.new(SemianError)

  module SemianConfig
    def initialize(semian: nil, **kwargs)
      super(**kwargs)

      @raw_semian_options = semian
    end

    def raw_semian_options
      @raw_semian_options.respond_to?(:call) ? @raw_semian_options.call(host, port) : @raw_semian_options
    end

    def semian_identifier
      return @semian_identifier if @semian_identifier

      identifier = begin
        name = (semian_options && semian_options[:name]) || "#{host}:#{port}/#{db}"
        :"redis_#{name}"
      end
      @semian_identifier = identifier unless semian_options && semian_options[:dynamic]
      identifier
    end

    define_method(:semian_options, Semian::Adapter.instance_method(:semian_options))
  end

  Config.include(SemianConfig)
  SentinelConfig.include(SemianConfig)
end

module Semian
  module RedisClientCommon
    def with_resource_timeout(temp_timeout)
      connect_timeout = self.connect_timeout
      read_timeout = self.read_timeout
      write_timeout = self.write_timeout

      begin
        self.timeout = temp_timeout
        yield
      ensure
        self.connect_timeout = connect_timeout
        self.read_timeout = read_timeout
        self.write_timeout = write_timeout
      end
    end

    def semian_identifier
      config.semian_identifier
    end

    private

    def semian_options
      config.semian_options
    end

    def raw_semian_options
      config.raw_semian_options
    end
  end

  module RedisClient
    EXCEPTIONS = [::RedisClient::ConnectionError, ::RedisClient::OutOfMemoryError].freeze

    include Semian::Adapter
    include RedisClientCommon

    private

    def resource_exceptions
      EXCEPTIONS
    end

    def ensure_connected(retryable: true)
      if block_given?
        super do |connection|
          acquire_semian_resource(adapter: :redis_client, scope: :query) do
            yield connection
          rescue ::RedisClient::OutOfMemoryError => error
            raise_oom_error(error)
          end
        end
      else
        super
      end
    end

    def raise_oom_error(error)
      if semian_options&.fetch(:open_circuit_on_oom, true)
        error.semian_identifier = semian_identifier
        raise error
      else
        new_error = ::RedisClient::RecoverableOutOfMemoryError.new(error.message)
        new_error.semian_identifier = semian_identifier
        raise new_error
      end
    end

    def connect
      acquire_semian_resource(adapter: :redis_client, scope: :connection) do
        super
      end
    end
  end

  module RedisClientPool
    include RedisClientCommon

    define_method(:semian_resource, Semian::Adapter.instance_method(:semian_resource))
    define_method(:clear_semian_resource, Semian::Adapter.instance_method(:clear_semian_resource))
  end
end

RedisClient.prepend(Semian::RedisClient)
RedisClient::Pooled.prepend(Semian::RedisClientPool)
