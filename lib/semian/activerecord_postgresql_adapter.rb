# frozen_string_literal: true

require "semian/adapter"
require "active_record"
require "active_record/connection_adapters/postgresql_adapter"

module ActiveRecord
  module ConnectionAdapters
    class PostgreSQLAdapter
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
  module ActiveRecordPostgreSQLAdapter
    include Semian::Adapter

    ResourceBusyError = ::ActiveRecord::ConnectionAdapters::PostgreSQLAdapter::ResourceBusyError
    CircuitOpenError = ::ActiveRecord::ConnectionAdapters::PostgreSQLAdapter::CircuitOpenError

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
        tx_command_statement = sql.end_with?("T", "K")

        # RELEASE SAVEPOINT. Nesting past _3 levels won't get bypassed.
        # Active Record does not send trailing spaces or `;`, so we are in the realm of hand crafted queries here.
        savepoint_statement = sql.end_with?("_1", "_2")
        unclear = sql.end_with?(" ", ";")

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
          port = config[:port] || 5432
          name = "#{host}:#{port}"
        end
        :"postgres_#{name}"
      end
      super
    end

    if ActiveRecord.version >= Gem::Version.new("8.2.a")
      def raw_execute(intent)
        compile_arel_in_intent(intent)
        intent.processed_sql ||= preprocess_query(intent.raw_sql) if intent.raw_sql
        return super if Semian::ActiveRecordPostgreSQLAdapter.query_allowlisted?(intent.processed_sql)

        acquire_semian_resource(adapter: :postgres_adapter, scope: :query) do
          super
        end
      end
    else
      def raw_execute(sql, ...)
        return super if Semian::ActiveRecordPostgreSQLAdapter.query_allowlisted?(sql)

        acquire_semian_resource(adapter: :postgres_adapter, scope: :query) do
          super
        end
      end
    end

    def active?
      acquire_semian_resource(adapter: :postgres_adapter, scope: :ping) do
        super
      end
    rescue ResourceBusyError, CircuitOpenError
      false
    end

    def with_resource_timeout(temp_timeout)
      prev_connect_timeout = @config[:connect_timeout]
      @config.merge!(connect_timeout: temp_timeout) # Create new client with temp_timeout for read timeout
      yield block
    ensure
      @config.merge!(connect_timeout: prev_connect_timeout)
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
      acquire_semian_resource(adapter: :postgres_adapter, scope: :connection) do
        super
      end
    end
  end
end

ActiveRecord::ConnectionAdapters::PostgreSQLAdapter.prepend(Semian::ActiveRecordPostgreSQLAdapter)
