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

      def resource_exceptions
        [
          ::GRPC::Unavailable,
          ::GRPC::Core::CallError,
          ::GRPC::BadStatus,
          ::GRPC::DeadlineExceeded,
        ]
      end

      def request_response(*)
        acquire_semian_resource(adapter: :grpc, scope: :request_response) { yield }
      end

      def client_streamer(*)
        acquire_semian_resource(adapter: :grpc, scope: :client_streamer) { yield }
      end

      def server_streamer(*)
        acquire_semian_resource(adapter: :grpc, scope: :server_streamer) { yield }
      end

      def bidi_streamer(*)
        acquire_semian_resource(adapter: :grpc, scope: :bidi_streamer) { yield }
      end
    end
  end
end
