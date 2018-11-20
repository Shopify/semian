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
    class Interceptor < ::GRPC::ClientInterceptor
      attr_reader :raw_semian_options
      include Semian::Adapter

      ResourceBusyError = ::GRPC::ResourceBusyError
      CircuitOpenError = ::GRPC::CircuitOpenError

      def initialize(host, semian_options)
        @host = host
        @raw_semian_options = semian_options
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
          self.exceptions = Semian::GRPC::Interceptor::DEFAULT_ERRORS.dup
        end
      end

      Semian::GRPC::Interceptor.reset_exceptions

      def resource_exceptions
        Semian::GRPC::Interceptor.exceptions
      end

      def request_response(request:, call:, method:, metadata: {})
        acquire_semian_resource(adapter: :grpc, scope: :request_response) {
          yield
        }
      end

      def client_streamer(request:, call:, method:, metadata: {})
        acquire_semian_resource(adapter: :grpc, scope: :client_stream) {
          yield
        }
      end

      def server_streamer(request:, call:, method:, metadata: {})
        acquire_semian_resource(adapter: :grpc, scope: :server_stream) {
          yield
        }
      end

      def bidi_streamer(request:, call:, method:, metadata: {})
        acquire_semian_resource(adapter: :grpc, scope: :bidi_stream) {
          yield
        }
      end
    end
  end
end
