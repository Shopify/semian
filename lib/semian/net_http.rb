# frozen_string_literal: true

require "semian/adapter"
require "net/http"
require "concurrent"

module Net
  ProtocolError.include(::Semian::AdapterError)

  class SemianError < ::Net::ProtocolError
    def initialize(semian_identifier, *args)
      super(*args)
      @semian_identifier = semian_identifier
    end
  end

  ResourceBusyError = Class.new(SemianError)
  CircuitOpenError = Class.new(SemianError)
end

module Semian
  module NetHTTP
    include Semian::Adapter

    ResourceBusyError = ::Net::ResourceBusyError
    CircuitOpenError = ::Net::CircuitOpenError

    class SemianConfigurationChangedError < RuntimeError
      def initialize(msg = "Cannot re-initialize semian_configuration")
        super
      end
    end

    def semian_identifier
      "nethttp_#{raw_semian_options[:name]}"
    end

    DEFAULT_ERRORS = [
      ::Timeout::Error, # includes ::Net::ReadTimeout and ::Net::OpenTimeout
      ::SocketError,
      ::Net::HTTPBadResponse,
      ::Net::HTTPHeaderSyntaxError,
      ::Net::ProtocolError,
      ::EOFError,
      ::IOError,
      ::SystemCallError, # includes ::Errno::EINVAL, ::Errno::ECONNRESET,
      # ::Errno::ECONNREFUSED, ::Errno::ETIMEDOUT, and more
    ].freeze # Net::HTTP can throw many different errors, this tries to capture most of them

    module ClassMethods
      def new(*args, semian: true)
        http = super(*args)
        http.instance_variable_set(:@semian_enabled, semian)
        http
      end
    end

    class << self
      attr_accessor :exceptions # rubocop:disable ThreadSafety/ClassAndModuleAttributes
      attr_reader :semian_configuration

      # rubocop:disable ThreadSafety/ClassInstanceVariable
      def semian_configuration=(configuration)
        # Only allow setting the configuration once in boot time
        raise Semian::NetHTTP::SemianConfigurationChangedError unless @semian_configuration.nil?

        @semian_configuration = configuration
      end

      def retrieve_semian_configuration(host, port)
        @semian_configuration.call(host, port) if @semian_configuration.respond_to?(:call)
      end
      # rubocop:enable ThreadSafety/ClassInstanceVariable

      def reset_exceptions
        self.exceptions = Concurrent::Array.new(DEFAULT_ERRORS.dup)
      end
    end

    Semian::NetHTTP.reset_exceptions

    def raw_semian_options
      @raw_semian_options ||= begin
        @raw_semian_options = Semian::NetHTTP.retrieve_semian_configuration(address, port)
        @raw_semian_options = @raw_semian_options.dup unless @raw_semian_options.nil?
      end
    end

    def resource_exceptions
      Semian::NetHTTP.exceptions
    end

    def disabled?
      raw_semian_options.nil? || @semian_enabled == false
    end

    def connect
      with_cleared_dynamic_options do
        return super if disabled?

        acquire_semian_resource(adapter: :http, scope: :connection) { super }
      end
    end

    def transport_request(*)
      with_cleared_dynamic_options do
        return super if disabled?

        acquire_semian_resource(adapter: :http, scope: :query) do
          handle_error_responses(super)
        end
      end
    end

    def with_resource_timeout(timeout)
      prev_read_timeout = read_timeout
      prev_open_timeout = open_timeout
      begin
        self.read_timeout = timeout
        self.open_timeout = timeout
        yield
      ensure
        self.read_timeout = prev_read_timeout
        self.open_timeout = prev_open_timeout
      end
    end

    private

    def handle_error_responses(result)
      if raw_semian_options.fetch(:open_circuit_server_errors, false)
        semian_resource.mark_failed(result) if result.is_a?(::Net::HTTPServerError)
      end
      result
    end

    def with_cleared_dynamic_options
      unless @resource_acquisition_in_progress
        @resource_acquisition_in_progress = true
        resource_acquisition_started = true
      end

      yield
    ensure
      if resource_acquisition_started
        if @raw_semian_options&.fetch(:dynamic, false)
          # Clear @raw_semian_options if the resource was flagged as dynamic.
          @raw_semian_options = nil
        end

        @resource_acquisition_in_progress = false
      end
    end
  end
end

Net::HTTP.prepend(Semian::NetHTTP)
Net::HTTP.singleton_class.prepend(Semian::NetHTTP::ClassMethods)
