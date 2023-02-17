# frozen_string_literal: true

require "semian/adapter"
require "net/http"

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
      attr_accessor :exceptions
      attr_reader :semian_configuration

      def semian_configuration=(configuration)
        raise Semian::NetHTTP::SemianConfigurationChangedError unless @semian_configuration.nil?

        @semian_configuration = configuration
      end

      def retrieve_semian_configuration(host, port)
        @semian_configuration.call(host, port) if @semian_configuration.respond_to?(:call)
      end

      def reset_exceptions
        self.exceptions = Semian::NetHTTP::DEFAULT_ERRORS.dup
      end
    end

    Semian::NetHTTP.reset_exceptions

    def time(name)
      starting = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      yield
    ensure
      ending = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      puts format("(#{name}): %f", (ending - starting).to_s)
    end

    def raw_semian_options
      return @raw_semian_options if @raw_semian_options

      # $call_count = 0 if $call_count.nil?
      # $call_count += 1
      # puts "$call_count: #{$call_count}"
      # puts caller[0]
      # raw_semian_options = time("call config block") { Semian::NetHTTP.retrieve_semian_configuration(address, port) }
      raw_semian_options = Semian::NetHTTP.retrieve_semian_configuration(address, port)
      if raw_semian_options
        raw_semian_options = raw_semian_options.dup

        if raw_semian_options.fetch(:deterministic, true)
          @semian_deterministic_config = true
          @raw_semian_options = raw_semian_options
        end
      end
      raw_semian_options
    end

    def resource_exceptions
      Semian::NetHTTP.exceptions
    end

    def disabled?(options = nil)
      options = raw_semian_options unless options
      options.nil? || @semian_enabled == false
    end

    def connect
      return super if disabled?(raw_semian_options)

      acquire_semian_resource(adapter: :http, scope: :connection) { super }
    end

    def transport_request(*)
      options = raw_semian_options
      return super if disabled?(options)

      acquire_semian_resource(adapter: :http, scope: :query, options: options) do
        handle_error_responses(super, options)
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

    def handle_error_responses(result, options)
      if options.fetch(:open_circuit_server_errors, false)
        semian_resource.mark_failed(result) if result.is_a?(::Net::HTTPServerError)
      end
      result
    end
  end
end

Net::HTTP.prepend(Semian::NetHTTP)
Net::HTTP.singleton_class.prepend(Semian::NetHTTP::ClassMethods)
