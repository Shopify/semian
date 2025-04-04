# frozen_string_literal: true

require "connection_pool"

# This is not a real Semian adapter, but a shim to make
# ConnectionPool instance carry semian_resource reference.
# Example:
#
# semian_resource = ::Redis.new(...).semian_resource
# ConnectionPool.new(size: 5, timeout: 0, semian_resource: semian_resource) do
#   ::Redis.new(...)
# end

class ConnectionPool
  module WithSemianResource
    def initialize(options = {}, &block)
      super
      @semian_resource = options[:semian_resource]
    end

    attr_reader :semian_resource
  end
end

ConnectionPool.prepend(ConnectionPool::WithSemianResource)
