# frozen_string_literal: true

require "semian/adapter"
require "net/http"

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

    class SemianConfigurationChangedError < RuntimeError
      def initialize(msg = "Cannot re-initialize semian_configuration")
        super
      end
    end

    class SemianPolicyChangedError < RuntimeError
      def initialize(msg = "Cannot change semian_policy after it has been set or used")
        super
      end
    end

    INHERIT_SEMIAN_POLICY = Object.new.freeze
    MAX_SEMIAN_POLICY_NAME_BYTES = 255
    private_constant :INHERIT_SEMIAN_POLICY, :MAX_SEMIAN_POLICY_NAME_BYTES

    def semian_identifier
      name = raw_semian_options&.fetch(:name, nil) || "#{address}_#{port}"
      "nethttp_#{name}"
    end

    DEFAULT_ERRORS = [
      ::Timeout::Error, # includes ::Net::ReadTimeout and ::Net::OpenTimeout
      ::SocketError,
      ::Net::HTTPBadResponse,
      ::Net::HTTPHeaderSyntaxError,
      ::Net::ProtocolError,
      ::EOFError,
      ::IOError,
      ::SystemCallError, # includes ::Errno::EINVAL, ::Errno::ECONNRESET,
      # ::Errno::ECONNREFUSED, ::Errno::ETIMEDOUT, and more
    ].freeze # Net::HTTP can throw many different errors, this tries to capture most of them

    module ClassMethods
      def new(*args, semian: INHERIT_SEMIAN_POLICY)
        http = super(*args)
        http.send(:initialize_semian_policy)
        http.semian_policy = semian unless semian.equal?(INHERIT_SEMIAN_POLICY)
        http
      end
    end

    class << self
      attr_accessor :exceptions # rubocop:disable ThreadSafety/ClassAndModuleAttributes
      attr_reader :semian_configuration

      # rubocop:disable ThreadSafety/ClassInstanceVariable
      def semian_configuration=(configuration)
        # Only allow setting the configuration once in boot time
        raise Semian::NetHTTP::SemianConfigurationChangedError unless @semian_configuration.nil?

        @semian_configuration = configuration
      end

      def retrieve_semian_configuration(host, port)
        @semian_configuration.call(host, port) if @semian_configuration.respond_to?(:call)
      end
      # rubocop:enable ThreadSafety/ClassInstanceVariable

      def reset_exceptions
        self.exceptions = Semian::NetHTTP::DEFAULT_ERRORS.dup
      end
    end

    Semian::NetHTTP.reset_exceptions

    def semian_policy
      semian_policy_mutex.synchronize { current_semian_policy }
    end

    def semian_policy=(policy)
      validate_semian_policy!(policy)

      semian_policy_mutex.synchronize do
        if instance_variable_defined?(:@semian_policy)
          return @semian_policy if @semian_policy == policy

          raise SemianPolicyChangedError
        end

        if @semian_policy_used
          return current_semian_policy if current_semian_policy == policy

          raise SemianPolicyChangedError
        end

        @semian_policy = immutable_semian_policy_value(policy)
      end
    end

    def raw_semian_options
      semian_policy_mutex.synchronize do
        @semian_policy_used = true
        return @raw_semian_options if @raw_semian_options_resolved

        policy = current_semian_policy
        @raw_semian_options = case policy
        when true
          Semian::NetHTTP.retrieve_semian_configuration(address, port)&.dup
        when false
          nil
        else
          policy
        end
        @raw_semian_options_resolved = policy == false || !@raw_semian_options.nil?
        @raw_semian_options
      end
    end

    def resource_exceptions
      Semian::NetHTTP.exceptions
    end

    def disabled?
      raw_semian_options.nil?
    end

    def connect
      with_cleared_dynamic_options do
        return super if disabled?

        acquire_semian_resource(adapter: :http, scope: :connection) { super }
      end
    end

    def transport_request(*)
      with_cleared_dynamic_options do
        return super if disabled?

        acquire_semian_resource(adapter: :http, scope: :query) do
          handle_error_responses(super, adapter: :http, scope: :query)
        end
      end
    end

    def with_resource_timeout(timeout)
      prev_read_timeout = read_timeout
      prev_open_timeout = open_timeout
      begin
        self.read_timeout = timeout
        self.open_timeout = timeout
        yield
      ensure
        self.read_timeout = prev_read_timeout
        self.open_timeout = prev_open_timeout
      end
    end

    private

    def initialize_semian_policy
      @semian_policy_mutex ||= Mutex.new
    end

    def semian_policy_mutex
      @semian_policy_mutex ||= Mutex.new
    end

    def current_semian_policy
      instance_variable_defined?(:@semian_policy) ? @semian_policy : true
    end

    def validate_semian_policy!(policy)
      unless policy == true || policy == false || policy.is_a?(Hash)
        raise ArgumentError, "semian_policy must be true, false, or a Hash"
      end
      return unless policy.is_a?(Hash)

      name = policy[:name]
      unless (name.is_a?(String) || name.is_a?(Symbol)) &&
          name.to_s.bytesize.between?(1, MAX_SEMIAN_POLICY_NAME_BYTES) &&
          !name.to_s.match?(/[[:cntrl:]]/)
        raise ArgumentError, "semian_policy :name must be a non-empty String or Symbol up to 255 bytes"
      end
      if policy[:dynamic]
        raise ArgumentError, "semian_policy cannot be dynamic"
      end
    end

    def immutable_semian_policy_value(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, option), copy|
          copy[immutable_semian_policy_value(key)] = immutable_semian_policy_value(option)
        end.freeze
      when Array
        value.map { |option| immutable_semian_policy_value(option) }.freeze
      when String
        value.dup.freeze
      else
        value
      end
    end

    def handle_error_responses(result, scope:, adapter:)
      if raw_semian_options.fetch(:open_circuit_server_errors, false)
        semian_resource.mark_failed(result, scope: scope, adapter: adapter) if result.is_a?(::Net::HTTPServerError)
      end
      result
    end

    def with_cleared_dynamic_options
      unless @resource_acquisition_in_progress
        @resource_acquisition_in_progress = true
        resource_acquisition_started = true
      end

      yield
    ensure
      if resource_acquisition_started
        semian_policy_mutex.synchronize do
          if @raw_semian_options&.fetch(:dynamic, false)
            # Clear @raw_semian_options if the resource was flagged as dynamic.
            @raw_semian_options = nil
            @raw_semian_options_resolved = false
          end
        end

        @resource_acquisition_in_progress = false
      end
    end
  end
end

Net::HTTP.prepend(Semian::NetHTTP)
Net::HTTP.singleton_class.prepend(Semian::NetHTTP::ClassMethods)
