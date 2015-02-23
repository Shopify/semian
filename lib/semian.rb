require 'logger'
require 'semian/instrumentable'

#
# === Overview
#
# Semian is a library that can be used to control access to external services.
#
# It's desirable to control access to external services so that in the case that one
# is slow or not responding, the performance of an entire system is not compromised.
#
# Semian uses the concept of a "resource" as an identifier that controls access
# to some external service. So for example, "mysql" or "redis" would be considered
# resources. If a system is sharded, like a database, you would typically create
# a resource for every shard.
#
# Resources are visible across an IPC namespace. This means that you can register a
# resource in one process and access it from another. This is useful in application
# servers like Unicorn that are multi-process. A resource is persistent. It will
# continue to exist even after the application exits, and will only be destroyed by
# manually removing it with the <code>ipcrm</code> command, calling Resource.destroy,
# or rebooting the machine.
#
# Each resource has a configurable number of tickets. Tickets are what controls
# access to the external service. If a client does not have a ticket, it cannot access
# a service. If there are no tickets available, the client will block for a configurable
# amount of time until a ticket is available. If there are no tickets available after
# the timeout period has elapsed, the client will be unable to access the service and
# an error will be raised.
#
# Resources also integrate a circuit breaker in order to fail faster and to let the
# resource the time to recover. If `error_threshold` errors happen in the span of `error_timeout`
# then the circuit will be opened and every attempt to acquire the resource will immediately fail.
# 
# Once in open state, after `error_timeout` is elapsed, the ciruit will transition in the half-open state.
# In that state a single error will fully re-open the circuit, and the circuit will transition back to the closed
# state only after the resource is acquired `success_threshold` consecutive times.
#
# A resource is registered by using the Semian.register method.
#
# ==== Examples
#
# ===== Registering a resource
#
#    Semian.register(:mysql_shard0, tickets: 10, timeout: 0.5, error_threshold: 3, error_timeout: 10, success_threshold: 2)
#
# This registers a new resource called <code>:mysql_shard0</code> that has 10 tickets andd a default timeout of 500 milliseconds.
#
# After 3 failures in the span of 10 seconds the circuit will be open.
# After an additional 10 seconds it will transition to half-open.
# And finally after 2 successulf acquisitions of the resource it will transition back to the closed state.
#
# ===== Using a resource
#
#    Semian[:mysql_shard0].acquire do
#      # Perform a MySQL query here
#    end
#
# This acquires a ticket for the <code>:mysql_shard0</code> resource. If we use the example above, the ticket count would
# be lowered to 9 when block is executed, then raised to 10 when the block completes.
#
# ===== Overriding the default timeout
#
#    Semian[:mysql_shard0].acquire(timeout: 1) do
#      # Perform a MySQL query here
#    end
#
# This is the same as the previous example, but overrides the timeout from the default value of 500 milliseconds to 1 second.
#
module Semian
  extend self
  extend Instrumentable

  BaseError = Class.new(StandardError)
  SyscallError = Class.new(BaseError)
  TimeoutError = Class.new(BaseError)
  InternalError = Class.new(BaseError)
  OpenCircuitError = Class.new(BaseError)

  module AdapterError
    attr_reader :semian_identifier

    def initialize(semian_identifier, *args)
      super(*args)
      @semian_identifier = semian_identifier
    end

    def to_s
      "[#{@semian_identifier}] #{super}"
    end
  end

  attr_accessor :logger

  self.logger = Logger.new(STDERR)

  # Registers a resource.
  #
  # +name+: Name of the resource - this can be either a string or symbol.
  #
  # +tickets+: Number of tickets. If this value is 0, the ticket count will not be set,
  # but the resource must have been previously registered otherwise an error will be raised.
  #
  # +permissions+: Octal permissions of the resource.
  #
  # +timeout+: Default timeout in seconds.
  #
  # +error_threshold+: The number of errors that will trigger the circuit opening.
  #
  # +error_timeout+: The duration in seconds since the last error after which the error count is reset to 0.
  #
  # +success_threshold+: The number of consecutive success after which an half-open circuit will be fully closed.
  #
  # +exceptions+: An array of exception classes that should be accounted as resource errors.
  #
  # Returns the registered resource.
  def register(name, tickets:, permissions: 0660, timeout: 0, error_threshold:, error_timeout:, success_threshold:, exceptions: [])
    circuit_breaker = CircuitBreaker.new(
      success_threshold: success_threshold,
      error_threshold: error_threshold,
      error_timeout: error_timeout,
      exceptions: Array(exceptions) + [::Semian::BaseError],
    )
    resource = Resource.new(name, tickets: tickets, permissions: permissions, timeout: timeout)
    resources[name] = ProtectedResource.new(resource, circuit_breaker)
  end

  def retrieve_or_register(name, **args)
    self[name] || register(name, **args)
  end

  # Retrieves a resource by name.
  def [](name)
    resources[name]
  end

  def destroy(name)
    if resource = resources.delete(name)
      resource.destroy
    end
  end

  # Retrieves a hash of all registered resources.
  def resources
    @resources ||= {}
  end
end

require 'semian/resource'
require 'semian/circuit_breaker'
require 'semian/protected_resource'
require 'semian/unprotected_resource'
require 'semian/platform'
if Semian.supported_platform?
  require 'semian/semian'
else
  Semian::MAX_TICKETS = 0
  Semian.logger.info("Semian is not supported on #{RUBY_PLATFORM} - all operations will no-op")
end
require 'semian/version'
