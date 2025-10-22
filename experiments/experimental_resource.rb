# frozen_string_literal: true

require "set"

# Add lib to load path if not already there
lib_path = File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift(lib_path) unless $LOAD_PATH.include?(lib_path)

require "semian/adapter"
require_relative "mock_service"

module Semian
  module Experiments
    # ExperimentalResource is a Semian adapter for the MockService.
    # It provides circuit breaker and bulkhead functionality for the mock service.
    class ExperimentalResource
      include Semian::Adapter

      attr_reader :service

      # Initialize the experimental resource adapter
      # @param name [String] The identifier for this resource
      # @param service [MockService] The mock service instance to wrap
      # @param options [Hash] Additional Semian options
      def initialize(name:, service:, **options)
        @name = name
        @service = service
        @raw_semian_options = options[:semian]
      end

      # Required by Adapter
      def semian_identifier
        @name.to_sym
      end

      # Make a request through Semian with circuit breaker protection
      # @param endpoint_index [Integer] The index of the endpoint to request (0-based)
      # @raises [CircuitOpenError] if the circuit is open
      # @raises [ResourceBusyError] if bulkhead limit is reached
      # @raises [MockService::TimeoutError] if the request times out
      # @raises [MockService::RequestError] if the request fails
      def request(endpoint_index, &block)
        acquire_semian_resource(scope: :request, adapter: :experimental) do
          @service.request(endpoint_index, &block)
        end
      end

      private

      attr_reader :raw_semian_options

      def resource_exceptions
        [MockService::RequestError, MockService::TimeoutError] # Exceptions that should trigger circuit breaker
      end

      # Error classes specific to this adapter
      class CircuitOpenError < ::Semian::BaseError
        def initialize(semian_identifier, *args)
          super(*args)
          @semian_identifier = semian_identifier
        end
      end

      class ResourceBusyError < ::Semian::BaseError
        def initialize(semian_identifier, *args)
          super(*args)
          @semian_identifier = semian_identifier
        end
      end

      # Re-export the service errors for backward compatibility
      RequestError = MockService::RequestError
      TimeoutError = MockService::TimeoutError
    end
  end
end
