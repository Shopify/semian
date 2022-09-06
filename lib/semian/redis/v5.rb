# frozen_string_literal: true

require "semian/redis_client"

class Redis
  BaseConnectionError.include(::Semian::AdapterError)
  OutOfMemoryError.include(::Semian::AdapterError)

  class SemianError < BaseConnectionError
    def initialize(semian_identifier, *args)
      super(*args)
      @semian_identifier = semian_identifier
    end
  end

  ResourceBusyError = Class.new(SemianError)
  CircuitOpenError = Class.new(SemianError)

  Client::ERROR_MAPPING.merge!(
    RedisClient::CircuitOpenError => Redis::CircuitOpenError,
    RedisClient::ResourceBusyError => Redis::ResourceBusyError,
  )
end

module Semian
  module RedisV5
    def semian_resource
      _client.semian_resource
    end

    def semian_identifier
      _client.semian_identifier
    end
  end

  module RedisV5Client
    private

    def translate_error!(error)
      redis_error = translate_error_class(error.class)
      if redis_error < ::Semian::AdapterError
        redis_error = redis_error.new(error.message)
        redis_error.semian_identifier = semian_identifier
      end
      raise redis_error, error.message, error.backtrace
    end
  end
end

::Redis.prepend(Semian::RedisV5)
::Redis::Client.prepend(Semian::RedisV5Client)
