require 'forwardable'
require 'logger'
require 'weakref'
require 'thread'

require 'semian/version'
require 'semian/instrumentable'
require 'semian/platform'
require 'semian/resource'
require 'semian/circuit_breaker'
require 'semian/protected_resource'
require 'semian/unprotected_resource'
require 'semian/simple_sliding_window'
require 'semian/simple_integer'
require 'semian/simple_state'
require 'semian/lru_hash'

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
# This registers a new resource called <code>:mysql_shard0</code> that has 10 tickets and a default timeout of 500 milliseconds.
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
module Semian
  extend self
  extend Instrumentable

  BaseError = Class.new(StandardError)
  SyscallError = Class.new(BaseError)
  TimeoutError = Class.new(BaseError)
  InternalError = Class.new(BaseError)
  OpenCircuitError = Class.new(BaseError)

  attr_accessor :maximum_lru_size, :minimum_lru_time
  self.maximum_lru_size = 500
  self.minimum_lru_time = 300

  def issue_disabled_semaphores_warning
    return if defined?(@warning_issued)
    @warning_issued = true
    if !sysv_semaphores_supported?
      logger.info("Semian sysv semaphores are not supported on #{RUBY_PLATFORM} - all operations will no-op")
    elsif disabled?
      logger.info("Semian semaphores are disabled, is this what you really want? - all operations will no-op")
    end
  end

  module AdapterError
    attr_accessor :semian_identifier

    def to_s
      if @semian_identifier
        "[#{@semian_identifier}] #{super}"
      else
        super
      end
    end
  end

  attr_accessor :logger

  self.logger = Logger.new(STDERR)

  # Registers a resource.
  #
  # +name+: Name of the resource - this can be either a string or symbol. (required)
  #
  # +circuit_breaker+: The boolean if you want a circuit breaker acquired for your resource. Default true.
  #
  # +bulkhead+: The boolean if you want a bulkhead to be acquired for your resource. Default true.
  #
  # +tickets+: Number of tickets. If this value is 0, the ticket count will not be set,
  # but the resource must have been previously registered otherwise an error will be raised.
  # Mutually exclusive with the 'quota' argument.
  #
  # +quota+: Calculate tickets as a ratio of the number of registered workers.
  # Must be greater than 0, less than or equal to 1. There will always be at least 1 ticket, as it
  # is calculated as (workers * quota).ceil
  # Mutually exclusive with the 'ticket' argument.
  # but the resource must have been previously registered otherwise an error will be raised. (bulkhead)
  #
  # +permissions+: Octal permissions of the resource. Default 0660. (bulkhead)
  #
  # +timeout+: Default timeout in seconds. Default 0. (bulkhead)
  #
  # +error_threshold+: The number of errors that will trigger the circuit opening. (circuit breaker required)
  #
  # +error_timeout+: The duration in seconds since the last error after which the error count is reset to 0.
  # (circuit breaker required)
  #
  # +success_threshold+: The number of consecutive success after which an half-open circuit will be fully closed.
  # (circuit breaker required)
  #
  # +exceptions+: An array of exception classes that should be accounted as resource errors. Default [].
  # (circuit breaker)
  #
  # Returns the registered resource.
  def register(name, **options)
    circuit_breaker = create_circuit_breaker(name, **options)
    bulkhead = create_bulkhead(name, **options)

    if circuit_breaker.nil? && bulkhead.nil?
      raise ArgumentError, 'Both bulkhead and circuitbreaker cannot be disabled.'
    end

    resources[name] = ProtectedResource.new(name, bulkhead, circuit_breaker)
  end

  def retrieve_or_register(name, **args)
    # If consumer who retrieved / registered by a Semian::Adapter, keep track
    # of who the consumer was so that we can clear the resource reference if needed.
    if consumer = args.delete(:consumer)
      if consumer.class.include?(Semian::Adapter)
        consumers[name] ||= []
        consumers[name] << WeakRef.new(consumer)
      end
    end
    self[name] || register(name, **args)
  end

  attr_reader :global_resource

  # create new global bulkhead
  # it's ok to overwrite existing global_bulkhead
  # as we use this only to track registered_workers count
  def register_global_worker
    @global_resource = create_bulkhead(:global, quota: 1)
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

  # Unregister will not destroy the semian resource, but it will
  # remove it from the hash of registered resources, and decrease
  # the number of registered workers.
  # Semian.destroy removes the underlying resource, but
  # Semian.unregister will remove all references, while preserving
  # the underlying semian resource (and sysV semaphore).
  # Also clears any semian_resources
  # in use by any semian adapters if the weak reference is still alive.
  def unregister(name)
    if resource = resources.delete(name)
      resource.bulkhead.unregister_worker if resource.bulkhead
      consumers_for_resource = consumers.delete(name) || []
      consumers_for_resource.each do |consumer|
        begin
          if consumer.weakref_alive?
            consumer.clear_semian_resource
          end
        rescue WeakRef::RefError
          next
        end
      end
    end
  end

  # Unregisters all resources
  def unregister_all_resources
    resources.keys.each do |resource|
      unregister(resource)
    end
  end

  # Retrieves a hash of all registered resources.
  def resources
    @resources ||= LRUHash.new
  end

  # Retrieves a hash of all registered resource consumers.
  def consumers
    @consumers ||= {}
  end

  def reset!
    @consumers = {}
    @resources = LRUHash.new
  end

  def thread_safe?
    return @thread_safe if defined?(@thread_safe)
    @thread_safe = true
  end

  def thread_safe=(thread_safe)
    @thread_safe = thread_safe
  end

  private

  def create_circuit_breaker(name, **options)
    circuit_breaker = options.fetch(:circuit_breaker, true)
    return unless circuit_breaker
    require_keys!([:success_threshold, :error_threshold, :error_timeout], options)

    exceptions = options[:exceptions] || []
    CircuitBreaker.new(
      name,
      success_threshold: options[:success_threshold],
      error_threshold: options[:error_threshold],
      error_timeout: options[:error_timeout],
      exceptions: Array(exceptions) + [::Semian::BaseError],
      half_open_resource_timeout: options[:half_open_resource_timeout],
      implementation: implementation(**options),
    )
  end

  def implementation(**options)
    # thread_safety_disabled will be replaced by a global setting
    # Semian is thread safe by default. It is possible
    # to modify the value by using Semian.thread_safe=
    unless options[:thread_safety_disabled].nil?
      logger.info(
        "NOTE: thread_safety_disabled will be replaced by a global setting" \
        "Semian is thread safe by default. It is possible" \
        "to modify the value by using Semian.thread_safe=",
      )
    end

    thread_safe = options[:thread_safety_disabled].nil? ? Semian.thread_safe? : !options[:thread_safety_disabled]
    thread_safe ? ::Semian::ThreadSafe : ::Semian::Simple
  end

  def create_bulkhead(name, **options)
    bulkhead = options.fetch(:bulkhead, true)
    return unless bulkhead

    permissions = options[:permissions] || 0660
    timeout = options[:timeout] || 0
    Resource.new(name, tickets: options[:tickets], quota: options[:quota], permissions: permissions, timeout: timeout)
  end

  def require_keys!(required, options)
    diff = required - options.keys
    unless diff.empty?
      raise ArgumentError, "Missing required arguments for Semian: #{diff}"
    end
  end
end

if Semian.semaphores_enabled?
  require 'semian/semian'
else
  Semian::MAX_TICKETS = 0
end

if defined? ActiveSupport
  ActiveSupport.on_load :active_record do
    require 'semian/rails'
  end
end
