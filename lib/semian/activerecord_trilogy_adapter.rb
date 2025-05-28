# frozen_string_literal: true

require "semian/adapter"
require "active_record"
require "active_record/connection_adapters/trilogy_adapter"

module ActiveRecord
  module ConnectionAdapters
    class TrilogyAdapter
      ActiveRecord::ActiveRecordError.include(::Semian::AdapterError)

      class SemianError < ConnectionNotEstablished
        def initialize(semian_identifier, *args)
          super(*args)
          @semian_identifier = semian_identifier
        end
      end

      ResourceBusyError = Class.new(SemianError)
      CircuitOpenError = Class.new(SemianError)
    end
  end
end

module Semian
  module ActiveRecordTrilogyAdapter
    include Semian::Adapter

    ResourceBusyError = ::ActiveRecord::ConnectionAdapters::TrilogyAdapter::ResourceBusyError
    CircuitOpenError = ::ActiveRecord::ConnectionAdapters::TrilogyAdapter::CircuitOpenError

    QUERY_ALLOWLIST = %r{\A(?:/\*.*?\*/)?\s*(ROLLBACK|COMMIT|RELEASE\s+SAVEPOINT)}i

    # The common case here is NOT to have transaction management statements, therefore
    # we are exploiting the fact that Active Record will use COMMIT/ROLLBACK as
    # the suffix of the command string and
    # name savepoints by level of nesting as `active_record_1` ... n.
    #
    # Since looking at the last characters in a string using `end_with?` is a LOT cheaper than
    # running a regex, we are returning early if the last characters of
    # the SQL statements are NOT the last characters of the known transaction
    # control statements.
    class << self
      def query_allowlisted?(sql, *)
        # COMMIT, ROLLBACK
        tx_command_statement = sql.end_with?("T") || sql.end_with?("K")

        # RELEASE SAVEPOINT. Nesting past _3 levels won't get bypassed.
        # Active Record does not send trailing spaces or `;`, so we are in the realm of hand crafted queries here.
        savepoint_statement = sql.end_with?("_1") || sql.end_with?("_2")
        unclear = sql.end_with?(" ") || sql.end_with?(";")

        if !tx_command_statement && !savepoint_statement && !unclear
          false
        else
          QUERY_ALLOWLIST.match?(sql)
        end
      rescue ArgumentError
        return false unless sql.valid_encoding?

        raise
      end
    end

    attr_reader :raw_semian_options, :semian_identifier

    def initialize(*options)
      *, config = options
      config = config.dup
      @raw_semian_options = config.delete(:semian)
      @semian_identifier = begin
        name = semian_options && semian_options[:name]
        unless name
          host = config[:host] || "localhost"
          port = config[:port] || 3306
          name = "#{host}:#{port}"
        end
        :"mysql_#{name}"
      end
      super
    end
    ruby2_keywords :raw_execute

    def active?
      acquire_semian_resource(adapter: :trilogy_adapter, scope: :ping) do
        super
      end
    rescue ResourceBusyError, CircuitOpenError
      false
    end

    def with_resource_timeout(temp_timeout)
      if @raw_connection.nil?
        prev_read_timeout = @config[:read_timeout] || 0
        @config.merge!(read_timeout: temp_timeout) # Create new client with temp_timeout for read timeout
      else
        prev_read_timeout = @raw_connection.read_timeout
        @raw_connection.read_timeout = temp_timeout
      end
      yield
    ensure
      @config.merge!(read_timeout: prev_read_timeout)
      @raw_connection&.read_timeout = prev_read_timeout
    end

    private

    def resource_exceptions
      [
        ActiveRecord::AdapterTimeout,
        ActiveRecord::ConnectionFailed,
        ActiveRecord::ConnectionNotEstablished,
      ]
    end

    def connect(*args)
      acquire_semian_resource(adapter: :trilogy_adapter, scope: :connection) do
        super
      end
    end
  end
end

ActiveRecord::ConnectionAdapters::TrilogyAdapter.prepend(Semian::ActiveRecordTrilogyAdapter)
