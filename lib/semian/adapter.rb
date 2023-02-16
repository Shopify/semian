# frozen_string_literal: true

require "semian"

module Semian
  module Adapter
    def semian_identifier
      raise NotImplementedError, "Semian adapters must implement a `semian_identifier` method"
    end

    def semian_resource(options = nil)
      return @semian_resource if @semian_resource

      options ||= semian_options
      name = semian_identifier

      case options
      when false
        @semian_resource = UnprotectedResource.new(name)
      when nil
        Semian.logger.info("Semian is not configured for #{self.class.name}: #{name}")
        @semian_resource = UnprotectedResource.new(name)
      else
        o = options.dup
        o.delete(:name)
        o[:consumer] = self
        o[:exceptions] ||= []
        o[:exceptions] += resource_exceptions
        resource = ::Semian.retrieve_or_register(name, **o)

        if o.fetch(:deterministic, true)
          @semian_resource = resource
        end

        resource
      end
    end

    def clear_semian_resource
      @semian_resource = nil
    end

    private

    def acquire_semian_resource(scope:, adapter:, options: nil, &block)
      return yield if resource_already_acquired?

      semian_resource(options).acquire(scope: scope, adapter: adapter, resource: self) do
        mark_resource_as_acquired(&block)
      end
    rescue ::Semian::OpenCircuitError => error
      last_error = semian_resource.circuit_breaker.last_error
      message = "#{error.message} caused by #{last_error.message}"
      last_error = nil unless last_error.is_a?(Exception) # Net::HTTPServerError is not an exception
      raise self.class::CircuitOpenError.new(semian_identifier, message), cause: last_error
    rescue ::Semian::BaseError => error
      raise self.class::ResourceBusyError.new(semian_identifier, error.message)
    rescue *resource_exceptions => error
      error.semian_identifier = semian_identifier if error.respond_to?(:semian_identifier=)
      raise
    end

    def semian_options
      if defined? @semian_options
        return @semian_options
      end

      options = raw_semian_options
      symbolized = options && options.map { |k, v| [k.to_sym, v] }.to_h
      if symbolized.nil? || symbolized == false || symbolized.fetch(:deterministic, true)
        @semian_options = symbolized
      end
      symbolized
    end

    def raw_semian_options
      raise NotImplementedError, "Semian adapters must implement a `raw_semian_options` method"
    end

    def resource_exceptions
      raise NotImplementedError, "Semian adapters must implement a `resource_exceptions` method"
    end

    def resource_already_acquired?
      @resource_acquired
    end

    def mark_resource_as_acquired
      previous = @resource_acquired
      @resource_acquired = true
      yield
    ensure
      @resource_acquired = previous
    end
  end
end
