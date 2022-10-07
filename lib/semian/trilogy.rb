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
      if query_allowlisted?(sql)
        super
      else
        acquire_semian_resource(adapter: :trilogy, scope: :query) do
          super
        end
      end
    end

    def with_resource_timeout(temp_timeout)
      # TODO: Check if conn is closed here using Trilogy#closed? instead of rescuing IOError
      # yield if closed?
      # This way, we can still acquire a new connection via Trilogy.new
      # if the old one was closed without running into problems
      prev_read_timeout = read_timeout
      self.read_timeout = temp_timeout
      yield
    # For now, let's rescue IOError and yield anyways to mimic eventually checking if the conn is closed
    rescue IOError => error
      raise unless error.message.match?(/connection closed/)

      yield
    ensure
      self.read_timeout = prev_read_timeout unless prev_read_timeout.nil?
    end

    private

    # Not sure: should we also rescue Errno::ECONNRESET, IOError?
    # I suspect we don't want to trigger circuit breaker logic for Errno::ECONNRESET bc this is a "fast failure"
    # I also think IOError is not relevant for now (only expecting this if the conn to the server has explicitly been closed)
    def resource_exceptions
      [
        ::Errno::ETIMEDOUT,
        ::Errno::ECONNREFUSED,
      ]
    end

    def acquire_semian_resource(**)
      super
    rescue ::Trilogy::Error => error
      # Network errors show up as Trilogy::Error <TRILOGY_CLOSED_CONNECTION>
      # What's the difference between <trilogy_query_send: TRILOGY_CLOSED_CONNECTION>
      # and <Connection reset by peer - trilogy_query_send> ?
      # Sometimes it seems like we'll see TRILOGY_CLOSED_CONNECTION because too much
      # time elapsed before making a query...? I don't think we want
      # to open the circuit in that case
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
      # The above regexp match can fail if the input SQL string contains binary
      # data that is not recognized as a valid encoding, in which case we just
      # return false.
      return false unless sql.valid_encoding?

      raise
    end
  end
end

Trilogy.prepend(Semian::Trilogy)
