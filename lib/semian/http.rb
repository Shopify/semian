# frozen_string_literal: true

require "semian/adapter"
require "http"

module HTTP
  HTTP::Error.include(Semian::AdapterError)

  class SemianError < HTTP::Error
    def initialize(semian_identifier, *args)
      super(*args)
      @semian_identifier = semian_identifier
    end
  end

  ResourceBusyError = Class.new(SemianError)
  CircuitOpenError = Class.new(SemianError)
end

module Semian
  module HTTP
    include Semian::Adapter

    ResourceBusyError = ::HTTP::ResourceBusyError
    CircuitOpenError = ::HTTP::CircuitOpenError

    class SemianConfigurationChangedError < RuntimeError
      def initialize(msg = "Cannot re-initialize semian_configuration")
        super
      end
    end

    def semian_identifier
      "http_gem_#{raw_semian_options[:name]}"
    end

    DEFAULT_ERRORS = [
      ::HTTP::Error,
    ].freeze

    module ClassMethods
      def new(*args, semian: true)
        http = super(*args)
        http.instance_variable_set(:@semian_enabled, semian)
        http
      end
    end

    class << self
      attr_accessor :exceptions
      attr_reader :semian_configuration

      def semian_configuration=(configuration)
        raise Semian::HTTP::SemianConfigurationChangedError unless @semian_configuration.nil?

        @semian_configuration = configuration
      end

      def retrieve_semian_configuration(host, port)
        @semian_configuration.call(host, port) if @semian_configuration.respond_to?(:call)
      end

      def reset_exceptions
        self.exceptions = Semian::HTTP::DEFAULT_ERRORS.dup
      end
    end

    Semian::HTTP.reset_exceptions

    def raw_semian_options
      @raw_semian_options
    end

    def resource_exceptions
      Semian::HTTP.exceptions
    end

    def disabled?
      raw_semian_options.nil? || @semian_enabled == false
    end

    def perform(request, _options)
      address = request.uri.host
      port = request.uri.port

      @raw_semian_options = Semian::HTTP.retrieve_semian_configuration(address, port)&.dup

      return super if disabled?

      acquire_semian_resource(adapter: :http_gem, scope: :query) do
        handle_error_responses(super)
      end
    ensure
      @raw_semian_options = nil
    end

    private

    def handle_error_responses(result)
      if @raw_semian_options.fetch(:open_circuit_server_errors, false) && error_result?(result)
        semian_resource.mark_failed(::HTTP::Error.new("Server returned status #{result&.status}"))
      end

      result
    end

    def error_result?(result)
      result.nil? || result.status.nil? || (500..599).cover?(result.status)
    end
  end
end

HTTP::Client.prepend(Semian::HTTP)
HTTP::Client.singleton_class.prepend(Semian::HTTP::ClassMethods)
