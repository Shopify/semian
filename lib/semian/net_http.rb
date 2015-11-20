require 'semian'
require 'semian/adapter'

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

    def semian_identifier
      Semian::NetHTTP.retrieve_semian_configuration(address, port)[:identifier]
    end

    DEFAULT_ERRORS = [
      ::Timeout::Error, # includes ::Net::ReadTimeout and ::Net::OpenTimeout
      ::TimeoutError, # alias for above
      ::SocketError,
      ::Net::HTTPBadResponse,
      ::Net::HTTPHeaderSyntaxError,
      ::Net::ProtocolError,
      ::EOFError,
      ::IOError,
      ::SystemCallError, # includes ::Errno::EINVAL, ::Errno::ECONNRESET, ::Errno::ECONNREFUSED, ::Errno::ETIMEDOUT, and more
    ].freeze # Net::HTTP can throw many different errors, this tries to capture most of them

    class << self
      attr_accessor :semian_configuration
      attr_accessor :exceptions

      def retrieve_semian_configuration(host, port)
        @semian_configuration.call(host, port) if @semian_configuration.respond_to?(:call)
      end

      def reset_exceptions
        self.exceptions = Semian::NetHTTP::DEFAULT_ERRORS.dup
      end
    end

    Semian::NetHTTP.reset_exceptions

    def raw_semian_options
      options = Semian::NetHTTP.retrieve_semian_configuration(address, port)
      unless options.nil?
        options = options.dup
        options.delete(:identifier)
      end
      options
    end

    def resource_exceptions
      Semian::NetHTTP.exceptions
    end

    def disabled?
      raw_semian_options.nil?
    end

    def connect
      return super if disabled?
      acquire_semian_resource(adapter: :http, scope: :connection) do
        super
      end
    end

    def request(*req)
      return super if disabled?
      acquire_semian_resource(adapter: :http, scope: :query) do
        super
      end
    end
  end
end

Net::HTTP.prepend(Semian::NetHTTP)
