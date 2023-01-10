# frozen_string_literal: true

require "semian/adapter"
require "grpc"

module GRPC
  GRPC::Unavailable.include(::Semian::AdapterError)
  GRPC::Unknown.include(::Semian::AdapterError)
  GRPC::ResourceExhausted.include(::Semian::AdapterError)

  class SemianError < GRPC::Unavailable
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

    class SemianConfigurationChangedError < RuntimeError
      def initialize(msg = "Cannot re-initialize semian_configuration")
        super
      end
    end

    class << self
      attr_accessor :exceptions
      attr_reader :semian_configuration

      def semian_configuration=(configuration)
        raise Semian::GRPC::SemianConfigurationChangedError unless @semian_configuration.nil?

        @semian_configuration = configuration
      end

      def retrieve_semian_configuration(host)
        @semian_configuration.call(host) if @semian_configuration.respond_to?(:call)
      end
    end

    def raw_semian_options
      @raw_semian_options ||= begin
        # If the host is empty, it's possible that the adapter was initialized
        # with the channel. Therefore, we look into the channel to find the host
        host = if @host.empty?
          @ch.target
        else
          @host
        end
        @raw_semian_options = Semian::GRPC.retrieve_semian_configuration(host)
        @raw_semian_options = @raw_semian_options.dup unless @raw_semian_options.nil?
      end
    end

    def semian_identifier
      @semian_identifier ||= raw_semian_options[:name]
    end

    def resource_exceptions
      [
        ::GRPC::DeadlineExceeded,
        ::GRPC::ResourceExhausted,
        ::GRPC::Unavailable,
        ::GRPC::Unknown,
      ]
    end

    def disabled?
      raw_semian_options.nil?
    end

    def request_response(*, **)
      return super if disabled?

      acquire_semian_resource_grpc(scope: :request_response) { super }
    end

    def client_streamer(*, **)
      return super if disabled?

      acquire_semian_resource_grpc(scope: :client_streamer) { super }
    end

    def server_streamer(*, **)
      return super if disabled?

      acquire_semian_resource_grpc(scope: :server_streamer) { super }
    end

    def bidi_streamer(*, **)
      return super if disabled?

      acquire_semian_resource_grpc(scope: :bidi_streamer) { super }
    end

    def acquire_semian_resource_grpc(scope:)
      acquire_semian_resource(adapter: :grpc, scope: scope) do
        result = yield
        handle_operation(result, scope) if result.is_a?(::GRPC::ActiveCall::Operation)
        result
      end
    end

    def handle_operation(operation, scope)
      execute = operation.singleton_method(:execute)
      operation.instance_variable_set(:@semian, self)
      operation.define_singleton_method(:execute) do
        @semian.send(:acquire_semian_resource, adapter: :grpc, scope: scope) { execute.call }
      end
    end
  end
end

::GRPC::ClientStub.prepend(Semian::GRPC)
