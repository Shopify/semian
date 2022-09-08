# frozen_string_literal: true

require "active_record/connection_adapters/abstract_adapter"

module Semian
  module Rails
    extend ActiveSupport::Concern

    module ClassMethods
      # Translate ConnectionNotEstablished errors to their original
      # cause if applicable. When we have a CircuitOpenErorr we don't
      # want the Active Record error, but rather the original cause.
      def new_client(config)
        super
      rescue ActiveRecord::ConnectionNotEstablished => e
        if e.cause.is_a?(Mysql2::CircuitOpenError)
          raise e.cause
        else
          raise
        end
      end
    end

    def semian_resource
      @semian_resource ||= client_connection.semian_resource
    end

    def reconnect
      @semian_resource = nil
      super
    end

    private

    # client_connection is an instance of a Mysql2::Client
    #
    # The conditionals here support multiple Rails versions.
    #   - valid_raw_connection is for 7.1.x and above
    #   - @raw_connection is for 7.0.x
    #   - @connection is for versions below 6.1.x and below
    def client_connection
      if respond_to?(:valid_raw_connection)
        valid_raw_connection
      elsif instance_variable_defined?(:@raw_connection)
        @raw_connection
      else
        @connection
      end
    end
  end
end

ActiveRecord::ConnectionAdapters::AbstractAdapter.prepend(Semian::Rails)
