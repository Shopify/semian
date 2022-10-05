# frozen_string_literal: true

require "semian/adapter"
require "trilogy"

# Trilogy raises a lot of native syscall errors...
# Would be good to work on this with upstream:
# - https://github.com/github/trilogy/issues/11
# - https://github.com/github/trilogy/pull/15
::Errno::ETIMEDOUT.include(::Semian::AdapterError)
::Errno::ECONNREFUSED.include(::Semian::AdapterError)
::Trilogy::Error.include(::Semian::AdapterError)

class Trilogy
  class SemianError < ::Trilogy::Error # TODO: What would be a good base exception?
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

    attr_reader :raw_semian_options, :semian_identifier

    def initialize(options)
      @raw_semian_options = options.delete(:semian)
      @semian_identifier = begin
        name = semian_options && semian_options[:name]
        unless name
          host = options[:host] || "localhost"
          port = options[:port] || 3306
          name = "#{host}:#{port}"
        end
        :"mysql_#{name}"
      end

      acquire_semian_resource(adapter: :trilogy, scope: :connection) do
        super
      end
    end

    def ping
      # TODO: make sure calling ping on a closed connection doesn't raise.
      # See: https://github.com/Shopify/semian/pull/396
      acquire_semian_resource(adapter: :trilogy, scope: :ping) do
        super
      end
    end

    def query(sql, *)
      if query_whitelisted?(sql)
        super
      else
        acquire_semian_resource(adapter: :trilogy, scope: :query) do
          super
        end
      end
    end

    private

    def resource_exceptions
      [
        ::Errno::ETIMEDOUT,
        ::Errno::ECONNREFUSED,
      ]
    end

    def acquire_semian_resource(**)
      super
    rescue ::Trilogy::Error => error
      # Need to make sure we don't re-raise Semian errors that are raised in #super
      if error.message.match?(/TRILOGY_CLOSED_CONNECTION/)
        semian_resource.mark_failed(error)
        error.semian_identifier = semian_identifier
      end
      raise
    end

    # TODO: share this with Mysql2
    QUERY_WHITELIST = Regexp.union(
      %r{\A(?:/\*.*?\*/)?\s*ROLLBACK}i,
      %r{\A(?:/\*.*?\*/)?\s*COMMIT}i,
      %r{\A(?:/\*.*?\*/)?\s*RELEASE\s+SAVEPOINT}i,
    )

    def query_whitelisted?(sql, *)
      QUERY_WHITELIST.match?(sql)
    rescue ArgumentError
      # The above regexp match can fail if the input SQL string contains binary
      # data that is not recognized as a valid encoding, in which case we just
      # return false.
      return false unless sql.valid_encoding?

      raise
    end
  end
end

Trilogy.prepend(Semian::Trilogy)
