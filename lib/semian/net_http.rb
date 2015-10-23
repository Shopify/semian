require 'semian'
require 'semian/adapter'
require 'net/https'
require 'open-uri'

module Net
  ::Net::ProtocolError.include(::Semian::AdapterError)

  class SemianError < ::Net::ProtocolError
    def initialize(semian_identifier, *args)
      super(*args)
      @semian_identifier = semian_identifier
    end
  end

  Net::ResourceBusyError = Class.new(SemianError)
  Net::CircuitOpenError = Class.new(SemianError)
end

module Semian
  module NetHTTP
    include Semian::Adapter

    ResourceBusyError = ::Net::ResourceBusyError
    CircuitOpenError = ::Net::CircuitOpenError

    DEFAULT_SEMIAN_OPTIONS = @raw_semian_options = {
      tickets: 3,
      success_threshold: 1,
      error_threshold: 3,
      error_timeout: 10,
    }

    def semian_identifier
      "http_#{address.tr('.', '_')}_#{port}"
    end

    def self.raw_semian_options(semian_identifier = "http_default".freeze)
      if @raw_semian_options.respond_to?(:call)
        @raw_semian_options.call(semian_identifier)
      else
        @raw_semian_options ||= DEFAULT_SEMIAN_OPTIONS
      end
    end

    def self.raw_semian_options=(options)
      @raw_semian_options = options
    end

    def raw_semian_options
      Semian::NetHTTP.raw_semian_options(semian_identifier)
    end

    def resource_exceptions
      @exceptions ||= [
        ::Timeout::Error, # includes ::Net::ReadTimeout and ::Net::OpenTimeout
        ::TimeoutError,
        ::Net::ProtocolError,
        ::Net::HTTPBadResponse,
        ::Net::HTTPHeaderSyntaxError,
        ::SocketError,
        ::IOError,
        ::EOFError,
        ::Resolv::ResolvError,
        ::OpenURI::HTTPError,
        ::OpenSSL::SSL::SSLError,
        ::SystemCallError, # includes ::Errno::EINVAL, ::Errno::ECONNRESET, ::Errno::ECONNREFUSED, ::Errno::ETIMEDOUT, and more
      ]
    end

    def connect
      acquire_semian_resource(adapter: :nethttp, scope: :connection) do
        super
      end
    end

    def request(*req)
      acquire_semian_resource(adapter: :nethttp, scope: :query) do
        super
      end
    end
  end
end

Net::HTTP.send(:prepend, Semian::NetHTTP)
