# typed: false
# frozen_string_literal: true

require "semian/adapter"
require "trilogy"

class Trilogy
  class SemianError < Trilogy::Error
    def initialize(semian_identifier, *args)
      super(*args)
      @semian_identifier = semian_identifier
    end
  end

  ResourceBusyError = Class.new(SemianError)
  CircuitOpenError = Class.new(SemianError)
end

module Semian
  module Trilogy
    include Semian::Adapter

    DEFAULT_HOST = "localhost"
    DEFAULT_PORT = 3306

    CONNECTION_ERROR = Regexp.union(
      /Can't connect to MySQL server on/i,
      /Lost connection to MySQL server/i,
      /MySQL server has gone away/i,
      /Too many connections/i,
      /closed MySQL connection/i,
      /Timeout waiting for a response/i,
    )

    ResourceBusyError = ::Trilogy::ResourceBusyError
    CircuitOpenError = ::Trilogy::CircuitOpenError
    PingFailure = Class.new(::Trilogy::Error)

    class SemianConfigurationChangedError < RuntimeError
      def initialize(msg = "Cannot re-initialize semian_configuration")
        super
      end
    end

    QUERY_WHITELIST = Regexp.union(
      %r{\A(?:/\*.*?\*/)?\s*ROLLBACK}i,
      %r{\A(?:/\*.*?\*/)?\s*COMMIT}i,
      %r{\A(?:/\*.*?\*/)?\s*RELEASE\s+SAVEPOINT}i,
    )

    class << self
      # The naked methods are exposed as `raw_query` for instrumentation purpose
      def included(base)
        base.send(:alias_method, :raw_query, :query)
        base.send(:remove_method, :query)

        base.send(:alias_method, :raw_ping, :ping)
        base.send(:remove_method, :ping)
      end

      attr_reader :semian_configuration

      def semian_configuration=(configuration)
        raise Semian::Trilogy::SemianConfigurationChangedError unless @semian_configuration.nil?

        @semian_configuration = configuration
      end

      def retrieve_semian_configuration(host, port)
        @semian_configuration.call(host, port) if @semian_configuration.respond_to?(:call)
      end
    end

    def semian_identifier
      @semian_identifier ||= begin
        name = semian_options && semian_options[:name]
        unless name
          host = DEFAULT_HOST
          port = DEFAULT_PORT
          name = "#{host}:#{port}"
        end
        :"trilogy_#{name}"
      end
    end

    def ping
      # Trilogy doesn't have a closed? method yet it looks like
      # return false if closed?

      result = nil
      acquire_semian_resource(adapter: :trilogy, scope: :ping) do
        result = raw_ping
        raise PingFailure, result.to_s unless result
      end
      result
    rescue ResourceBusyError, CircuitOpenError, PingFailure
      false
    end

    def query(*args)
      if query_whitelisted?(*args)
        raw_query(*args)
      else
        acquire_semian_resource(adapter: :mysql, scope: :query) { raw_query(*args) }
      end
    end

    private

    EXCEPTIONS = [].freeze
    def resource_exceptions
      EXCEPTIONS
    end

    def query_whitelisted?(sql, *)
      QUERY_WHITELIST =~ sql
    rescue ArgumentError
      # The above regexp match can fail if the input SQL string contains binary
      # data that is not recognized as a valid encoding, in which case we just
      # return false.
      return false unless sql.valid_encoding?

      raise
    end

    def connect(*args)
      acquire_semian_resource(adapter: :trilogy, scope: :connection) do
        new(*args)
      end
    end

    def acquire_semian_resource(**)
      super
    rescue ::Trilogy::Error => error
      if error.is_a?(PingFailure) || (!error.is_a?(::Trilogy::SemianError) && error.message.match?(CONNECTION_ERROR))
        semian_resource.mark_failed(error)
        error.semian_identifier = semian_identifier
      end
      raise
    end

    def raw_semian_options
      @raw_semian_options ||= begin
        @raw_semian_options = Semian::Trilogy.retrieve_semian_configuration(DEFAULT_HOST, DEFAULT_PORT)
        @raw_semian_options = @raw_semian_options.dup unless @raw_semian_options.nil?
      end
    end
  end
end

::Trilogy.include(Semian::Trilogy)
