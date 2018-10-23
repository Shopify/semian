require 'semian/adapter'
require 'grpc'

module GRPC
  GRPC::BadStatus.include(::Semian::AdapterError)

  class SemianError < GRPC::BadStatus
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
      set_raw_semian_options(args.last)
      args.pop
      super(*args)
    end

    def semian_identifier
      @semian_identifier ||= :"grpc_#{@host}"
    end

    DEFAULT_ERRORS = [
      ::GRPC::Unavailable,
      ::GRPC::Core::CallError,
      ::GRPC::BadStatus,
    ].freeze

    class << self
      attr_accessor :exceptions

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

    def set_raw_semian_options(semian_options)
      @tickets = semian_options[:tickets]
      @success_threshold = semian_options[:success_threshold]
      @error_threshold = semian_options[:error_threshold]
      @error_timeout = semian_options[:error_timeout]
      @name = semian_options[:name]
    end

    def raw_semian_options
      {
        tickets: @tickets,
        success_threshold: @success_threshold,
        error_threshold: @error_threshold,
        error_timeout: @error_timeout,
        name: @name
      }
    end
  end
end

::GRPC::ClientStub.prepend(Semian::GRPC)
