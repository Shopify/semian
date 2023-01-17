# frozen_string_literal: true

require "semian/adapter"
require "trilogy"

# Keep an eye on this in case we move away from the Module pattern upstream
::Trilogy::BaseError.include(::Semian::AdapterError)

class Trilogy
  class SemianError < ::Trilogy::BaseError
    def initialize(semian_identifier, *args)
      super(*args)
      @semian_identifier = semian_identifier
    end
  end

  ResourceBusyError = Class.new(SemianError)
  CircuitOpenError = Class.new(SemianError)

  # The naked methods are exposed as `raw_query` and `raw_ping` for instrumentation purpose
  alias_method(:raw_query, :query)
  remove_method(:query)

  alias_method(:raw_ping, :ping)
  remove_method(:ping)
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

    def query(*args)
      if query_allowlisted?(*args)
        raw_query(*args)
      else
        acquire_semian_resource(adapter: :trilogy, scope: :query) do
          raw_query(*args)
        end
      end
    end

    def ping
      return false if closed?

      acquire_semian_resource(adapter: :trilogy, scope: :ping) do
        raw_ping
      end
    end

    private

    def resource_exceptions
      [::Trilogy::ConnectionError, ::Trilogy::TimeoutError]
    end

    def acquire_semian_resource(**)
      super
    rescue ::Trilogy::QueryError => error
      if error.message.match?(/TRILOGY_CLOSED_CONNECTION/)
        semian_resource.mark_failed(error)
        error.semian_identifier = semian_identifier
      end
      raise
    end

    # TODO: share this with Mysql2
    QUERY_ALLOWLIST = Regexp.union(
      %r{\A(?:/\*.*?\*/)?\s*ROLLBACK}i,
      %r{\A(?:/\*.*?\*/)?\s*COMMIT}i,
      %r{\A(?:/\*.*?\*/)?\s*RELEASE\s+SAVEPOINT}i,
    )

    def query_allowlisted?(sql, *)
      QUERY_ALLOWLIST.match?(sql)
    rescue ArgumentError
      return false unless sql.valid_encoding?

      raise
    end
  end
end

::Trilogy.prepend(Semian::Trilogy)
