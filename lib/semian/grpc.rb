require 'semian/adapter'
require 'grpc'

module GRPC
  GRPC::BadStatus.include(::Semian::AdapterError)

  class SemianError < GRPC::BadStatus
    attr_reader :details

    def initialize(semian_identifier, *args)
      super(*args)
      @details = message
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

    # def initialize(host, creds, **opts)
    #   @raw_semian_options = opts[:semian_options]
    #   opts.delete(:semian_options)
    #   super(host, creds, opts)
    # end

    class SemianConfigurationChangedError < RuntimeError
      def initialize(msg = "Cannot re-initialize semian_configuration")
        super
      end
    end

    def raw_semian_options
      @raw_semian_options ||= begin
        @raw_semian_options = Semian::GRPC.retrieve_semian_configuration(@host)
        @raw_semian_options = @raw_semian_options.dup unless @raw_semian_options.nil?
      end
    end

    def semian_identifier
      @semian_identifier ||= raw_semian_options[:name]
    end

    def resource_exceptions
      [
        ::GRPC::DeadlineExceeded,
        ::GRPC::InvalidArgument,
        ::GRPC::Cancelled,
        ::GRPC::Unknown,
        ::GRPC::NotFound,
        ::GRPC::PermissionDenied,
        ::GRPC::ResourceExhausted,
        ::GRPC::Aborted,
        ::GRPC::Unavailable,
        ::GRPC::BadStatus,
      ]
    end

    class << self
      attr_accessor :exceptions
      attr_reader :semian_configuration

      def semian_configuration=(configuration)
        raise Semian::GRPC::SemianConfigurationChangedError unless @semian_configuration.nil?
        @semian_configuration = configuration
      end

      def retrieve_semian_configuration(host)
        if @semian_configuration.respond_to?(:call)
          @semian_configuration.call(host)
        else
          @semian_configuration
        end
      end

      def reset_semian_configuration
        @semian_configuration = nil
      end
    end

    def request_response(*args)
      acquire_semian_resource(adapter: :grpc, scope: :request_response) { super(*args) }
    end

    def client_streamer(*args)
      acquire_semian_resource(adapter: :grpc, scope: :client_streamer) { super(*args) }
    end

    def server_streamer(*args)
      acquire_semian_resource(adapter: :grpc, scope: :server_streamer) { super(*args) }
    end

    def bidi_streamer(*args)
      acquire_semian_resource(adapter: :grpc, scope: :bidi_streamer) { super(*args) }
    end
  end
end

::GRPC::ClientStub.prepend(Semian::GRPC)
