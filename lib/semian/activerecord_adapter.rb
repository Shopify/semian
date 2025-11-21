# frozen_string_literal: true

require "semian/adapter"
require "active_record"

module Semian
  module ActiveRecordAdapter
    QUERY_ALLOWLIST = %r{\A(?:/\*.*?\*/)?\s*(ROLLBACK|COMMIT|RELEASE\s+SAVEPOINT)}i

    module ClassMethods
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

    class << self
      def included(base)
        base.extend(ClassMethods)
        base.class_eval do
          attr_reader(:raw_semian_options, :semian_identifier)
        end
      end
    end

    def initialize(*options)
      *, config = options
      config = config.dup
      @raw_semian_options = config.delete(:semian)
      @semian_identifier = begin
        name = semian_options && semian_options[:name]
        unless name
          host = config[:host] || "localhost"
          port = config[:port] || semian_adapter_default_port
          name = "#{host}:#{port}"
        end
        :"#{semian_adapter_identifier_prefix}_#{name}"
      end
      super
    end

    if ActiveRecord.version >= Gem::Version.new("8.2.a")
      def execute_intent(intent)
        return super if self.class.query_allowlisted?(intent.processed_sql)

        acquire_semian_resource(adapter: semian_adapter_name, scope: :query) do
          super
        end
      end
    else
      def raw_execute(sql, *args, **kwargs, &block)
        if self.class.query_allowlisted?(sql)
          super
        else
          acquire_semian_resource(adapter: semian_adapter_name, scope: :query) do
            super(sql, *args, **kwargs, &block)
          end
        end
      end
    end

    def active?
      acquire_semian_resource(adapter: semian_adapter_name, scope: :ping) do
        super
      end
    rescue resource_busy_error_class, circuit_open_error_class
      false
    end

    def with_resource_timeout
      raise NotImplementedError, "#{self.class} must implement a `with_resource_timeout` method"
    end

    private

    def resource_exceptions
      [
        ActiveRecord::AdapterTimeout,
        ActiveRecord::ConnectionFailed,
        ActiveRecord::ConnectionNotEstablished,
      ]
    end

    def resource_busy_error_class
      self.class::ResourceBusyError
    end

    def circuit_open_error_class
      self.class::CircuitOpenError
    end

    def connect(*args)
      acquire_semian_resource(adapter: semian_adapter_name, scope: :connection) do
        super
      end
    end

    def semian_adapter_name
      raise NotImplementedError, "#{self.class} must implement an `semian_adapter_name` method"
    end

    def semian_adapter_default_port
      raise NotImplementedError, "#{self.class} must implement an `semian_adapter_default_port` method"
    end

    def semian_adapter_identifier_prefix
      raise NotImplementedError, "#{self.class} must implement an `semian_adapter_identifier_prefix` method"
    end
  end
end
