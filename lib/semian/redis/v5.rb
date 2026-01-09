# frozen_string_literal: true

require "semian/redis_client"

class Redis
  BaseConnectionError.include(::Semian::AdapterError)
  OutOfMemoryError.include(::Semian::AdapterError)
  OutOfMemoryError.class_eval do
    attr_accessor :open_circuit_on_oom

    # By default, OOM errors open circuits (backward compatible behavior).
    # Set `open_circuit_on_oom: false` to disable this if you want reads/deletes
    # to continue working when Redis is OOM, allowing it to recover.
    def marks_semian_circuits?
      @open_circuit_on_oom != false
    end
  end

  class ReadOnlyError < Redis::BaseConnectionError
    # A ReadOnlyError is a fast failure and we don't want to track these errors so that we can reconnect
    # to the new primary ASAP
    def marks_semian_circuits?
      false
    end
  end

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
    def translate_error!(error)
      redis_error = translate_error_class(error.class)
      if redis_error < ::Semian::AdapterError
        redis_error = redis_error.new(error.message)
        redis_error.semian_identifier = error.semian_identifier
        if error.respond_to?(:open_circuit_on_oom) && redis_error.respond_to?(:open_circuit_on_oom=)
          redis_error.open_circuit_on_oom = error.open_circuit_on_oom
        end
      end
      raise redis_error, error.message, error.backtrace
    end
  end
end

::Redis.prepend(Semian::RedisV5)
::Redis::Client.singleton_class.prepend(Semian::RedisV5Client)
