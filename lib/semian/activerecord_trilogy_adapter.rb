# frozen_string_literal: true

require "semian/activerecord_adapter"
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
    include Semian::ActiveRecordAdapter

    class << self
      def prepended(base)
        base.extend(Semian::ActiveRecordAdapter::ClassMethods)
      end
    end

    def with_resource_timeout(temp_timeout)
      if @raw_connection.nil?
        prev_read_timeout = @config[:read_timeout] || 0
        @config.merge!(read_timeout: temp_timeout)
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

    def semian_adapter_name = :trilogy_adapter

    def semian_adapter_default_port = 3306

    def semian_adapter_identifier_prefix = :mysql
  end
end

ActiveRecord::ConnectionAdapters::TrilogyAdapter.prepend(Semian::ActiveRecordTrilogyAdapter)
