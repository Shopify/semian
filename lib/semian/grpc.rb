require 'semian/adapter'
require 'grpc'

module GRPC
  GRPC::BadStatus.include(::Semian::AdapterError)

  class SemianError < GRPC::BadStatus
    # TODO
    def initialize(semian_identifier, *args)
      super(*args)
      @semian_identifier = semian_identifier
    end
  end

  ResourceBusyError = Class.new(SemianError)
  CircuitOpenError = Class.new(SemianError)
end

module Semian
  module GRPC
    include Semian::Adapter

    ResourceBusyError = ::GRPC::ResourceBusyError
    CircuitOpenError = ::GRPC::CircuitOpenError

    def initialize(*args)
      @host = args.first
      super(*args)
    end

    def semian_identifier
      @semian_identifier ||= begin
        :"grpc_#{@host}"
      end
    end

    DEFAULT_ERRORS = [
      ::GRPC::Unavailable,
      ::GRPC::Core::CallError,
      ::GRPC::BadStatus,
    ].freeze

    class << self
      attr_accessor :exceptions
      attr_reader :semian_configuration

      def semian_configuration=(configuration)
        raise Semian::GRPC::SemianConfigurationChangedError unless @semian_configuration.nil?
        @semian_configuration = configuration
      end

      def retrieve_semian_configuration(host, port)
        @semian_configuration.call(host, port) if @semian_configuration.respond_to?(:call)
      end

      def reset_exceptions
        self.exceptions = Semian::GRPC::DEFAULT_ERRORS.dup
      end
    end

    Semian::GRPC.reset_exceptions

    def resource_exceptions
      Semian::GRPC.exceptions
    end

    def request_response(*args)
      acquire_semian_resource(adapter: :grpc, scope: :connection) { super(*args) }
    end

    def raw_semian_options
      # TODO
      {
        :tickets=>3,
        :success_threshold=>1,
        :error_threshold=>3,
        :error_timeout=>10,
        :name=> @host
      }
    end

    private

    def acquire_semian_resource(*)
      super
    # rescue
    # TODO
    end
  end
end

::GRPC::ClientStub.prepend(Semian::GRPC)
