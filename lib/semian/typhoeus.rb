require 'semian/adapter'
require 'typhoeus'
require 'uri'

module Typhoeus
  Errors::TyphoeusError.include(::Semian::AdapterError)

  class SemianError < ::Typhoeus::Errors::TyphoeusError
    def initialize(semian_identifier, *args)
      super(*args)
      @semian_identifier = semian_identifier
    end
  end

  ResourceBusyError = Class.new(SemianError)
  CircuitOpenError = Class.new(SemianError)
end

module Semian
  module Typhoeus
    include Semian::Adapter

    ResourceBusyError = ::Typhoeus::ResourceBusyError
    CircuitOpenError = ::Typhoeus::CircuitOpenError

    class SemianConfigurationChangedError < RuntimeError
      def initialize(msg = "Cannot re-initialize semian_configuration")
        super
      end
    end

    def semian_identifier
      "typhoeus_#{raw_semian_options[:name]}"
    end

    DEFAULT_ERRORS = [
      ::Timeout::Error,
      ::SocketError,
      ::Typhoeus::Errors::NoStub,
      ::Typhoeus::Errors::TyphoeusError,
      ::EOFError,
      ::IOError,
      ::SystemCallError, # includes ::Errno::EINVAL, ::Errno::ECONNRESET, ::Errno::ECONNREFUSED, ::Errno::ETIMEDOUT, and more
    ].freeze # Typhoeus can throw many different errors, this tries to capture most of them

    class << self
      attr_accessor :exceptions
      attr_reader :semian_configuration

      def semian_configuration=(configuration)
        raise Semian::Typhoeus::SemianConfigurationChangedError unless @semian_configuration.nil?
        @semian_configuration = configuration
      end

      def retrieve_semian_configuration(host, port)
        @semian_configuration.call(host, port) if @semian_configuration.respond_to?(:call)
      end

      def reset_exceptions
        self.exceptions = Semian::Typhoeus::DEFAULT_ERRORS.dup
      end
    end

    Semian::Typhoeus.reset_exceptions

    def raw_semian_options
      @raw_semian_options ||= begin
        uri = URI.parse(url)
        @raw_semian_options = Semian::Typhoeus.retrieve_semian_configuration(uri.host, uri.port)
        @raw_semian_options = @raw_semian_options.dup unless @raw_semian_options.nil?
      end
    end

    def resource_exceptions
      Semian::Typhoeus.exceptions
    end

    def disabled?
      raw_semian_options.nil?
    end

    def run
      return super if disabled?

      acquire_semian_resource(adapter: :typhoeus, scope: :query) { handle_error_responses(super) }
    end

    private

    def handle_error_responses(result)
      semian_resource.mark_failed(TyphoeusError.new(result.return_message)) if !result.success?
      result
    end
  end
end

class TyphoeusError < StandardError
  def initialize(msg)
    super(msg)
  end
end

Typhoeus::Request.prepend(Semian::Typhoeus)