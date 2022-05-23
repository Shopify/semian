# frozen_string_literal: true

require "semian/adapter"
require "redis-client"

class RedisClient
  ConnectionError.include(::Semian::AdapterError)

  class SemianError < ConnectionError
    def initialize(semian_identifier, *args)
      super(*args)
      @semian_identifier = semian_identifier
    end
  end

  ResourceBusyError = Class.new(SemianError)
  CircuitOpenError = Class.new(SemianError)

  module SemianConfig
    attr_reader :raw_semian_options

    def initialize(semian: nil, **kwargs)
      super(**kwargs)

      @raw_semian_options = semian
    end

    def semian_identifier
      @semian_identifier ||= begin
        name = (semian_options && semian_options[:name]) || "#{host}:#{port}/#{db}"
        :"redis_#{name}"
      end
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
    EXCEPTIONS = [::RedisClient::ConnectionError]

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
          end
        end
      else
        super
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
RedisClient::Pooled.prepend(Semian::RedisClient)
