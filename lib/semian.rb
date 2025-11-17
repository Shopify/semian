# frozen_string_literal: true

require "forwardable"
require "logger"
require "weakref"
require "thread"
require "concurrent-ruby"

require "semian/version"
require "semian/instrumentable"
require "semian/platform"
require "semian/resource"
require "semian/circuit_breaker"
require "semian/adaptive_circuit_breaker"
require "semian/protected_resource"
require "semian/unprotected_resource"
require "semian/simple_sliding_window"
require "semian/simple_integer"
require "semian/simple_state"
require "semian/lru_hash"
require "semian/configuration_validator"

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
# Once in open state, after `error_timeout` is elapsed, the circuit will transition in the half-open state.
# In that state a single error will fully re-open the circuit, and the circuit will transition back to the closed
# state only after the resource is acquired `success_threshold` consecutive times.
#
# A resource is registered by using the Semian.register method.
#
# ==== Examples
#
# ===== Registering a resource
#
#    Semian.register(
#      :mysql_shard0,
#      tickets: 10,
#      timeout: 0.5,
#      error_threshold: 3,
#      error_timeout: 10,
#      success_threshold: 2,
#    )
#
# This registers a new resource called <code>:mysql_shard0</code> that has 10 tickets and
# a default timeout of 500 milliseconds.
#
# After 3 failures in the span of 10 seconds the circuit will be open.
# After an additional 10 seconds it will transition to half-open.
# And finally after 2 successful acquisitions of the resource it will transition back to the closed state.
#
# ===== Using a resource
#
#    Semian[:mysql_shard0].acquire do
#      # Perform a MySQL query here
#    end
#
# This acquires a ticket for the <code>:mysql_shard0</code> resource. If we use the example above,
# the ticket count would be lowered to 9 when block is executed, then raised to 10 when the block completes.
#
# ===== Overriding the default timeout
#
#    Semian[:mysql_shard0].acquire(timeout: 1) do
#      # Perform a MySQL query here
#    end
#
# This is the same as the previous example, but overrides the timeout
# from the default value of 500 milliseconds to 1 second.
module Semian
  extend self
  extend Instrumentable

  BaseError = Class.new(StandardError)
  SyscallError = Class.new(BaseError)
  TimeoutError = Class.new(BaseError)
  InternalError = Class.new(BaseError)
  OpenCircuitError = Class.new(BaseError)
  SemaphoreMissingError = Class.new(BaseError)

  attr_accessor :maximum_lru_size, :minimum_lru_time, :default_permissions, :namespace, :default_force_config_validation

  self.maximum_lru_size = 500
  self.minimum_lru_time = 300 # 300 seconds / 5 minutes
  self.default_permissions = 0660
  self.default_force_config_validation = false

  # We only allow disabling thread-safety for parts of the code that are on the hot path.
  # Since locking there could have a significant impact. Everything else is enforced thread safety
  def thread_safe?
    return @thread_safe if defined?(@thread_safe)

    @thread_safe = true
  end

  def thread_safe=(thread_safe)
    @thread_safe = thread_safe
  end

  @reset_mutex = Mutex.new

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
      message = super
      if @semian_identifier
        prefix = "[#{@semian_identifier}] "
        # When an error is created from another error's message it might
        # already have a semian identifier in their message
        unless message.start_with?(prefix)
          message = "#{prefix}#{message}"
        end
      end
      message
    end
  end

  attr_accessor :logger

  self.logger = Logger.new($stderr)

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
  # +permissions+: Octal permissions of the resource. Default to +Semian.default_permissions+ (0660). (bulkhead)
  #
  # +timeout+: Default timeout in seconds. Default 0. (bulkhead)
  #
  # +error_timeout+: The duration in seconds since the last error after which the error count is reset to 0.
  # (circuit breaker required)
  #
  # +error_threshold+: The amount of errors that must happen within error_timeout amount of time to open
  # the circuit. (circuit breaker required)
  #
  # +error_threshold_timeout+: The duration in seconds to examine number of errors to compare with error_threshold.
  # Default same as error_timeout. (circuit breaker)
  #
  # +error_threshold_timeout_enabled+: flag to enable/disable filter time window based error eviction
  # (error_threshold_timeout). Default true. (circuit breaker)
  #
  # +success_threshold+: The number of consecutive success after which an half-open circuit will be fully closed.
  # (circuit breaker required)
  #
  # +exceptions+: An array of exception classes that should be accounted as resource errors. Default [].
  # (circuit breaker)
  #
  # +adaptive_circuit_breaker+: Enable adaptive circuit breaker using PID controller. Default false.
  # When enabled, this replaces the traditional circuit breaker with an adaptive version
  # that dynamically adjusts rejection rates based on service health. (adaptive circuit breaker)
  #
  # Returns the registered resource.
  def register(name, **options)
    return UnprotectedResource.new(name) if ENV.key?("SEMIAN_DISABLED")

    # Validate configuration before proceeding
    ConfigurationValidator.new(name, options).validate!

    circuit_breaker = if options[:adaptive_circuit_breaker]
      create_adaptive_circuit_breaker(name, **options)
    else
      create_circuit_breaker(name, **options)
    end

    bulkhead = create_bulkhead(name, **options)

    resources[name] = ProtectedResource.new(name, bulkhead, circuit_breaker)
  end

  def retrieve_or_register(name, **args)
    # If consumer who retrieved / registered by a Semian::Adapter, keep track
    # of who the consumer was so that we can clear the resource reference if needed.
    consumer = args.delete(:consumer)
    if consumer&.class&.include?(Semian::Adapter) && !args[:dynamic]
      consumer_set = consumers.compute_if_absent(name) { ObjectSpace::WeakMap.new }
      consumer_set[consumer] = true
    end
    self[name] || register(name, **args)
  end

  # Retrieves a resource by name.
  def [](name)
    resources[name]
  end

  def destroy(name)
    resource = resources.delete(name)
    resource&.destroy
  end

  def destroy_all_resources
    resources.values.each(&:destroy)
    resources.clear
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
    resource = resources.delete(name)
    if resource
      resource.bulkhead&.unregister_worker
      consumers_for_resource = consumers.delete(name) || ObjectSpace::WeakMap.new
      consumers_for_resource.each_key(&:clear_semian_resource)
    end
  end

  # Unregisters all resources
  def unregister_all_resources
    resources.keys.each do |resource|
      unregister(resource)
    end
  end

  def reset!
    @reset_mutex.synchronize do
      @consumers = Concurrent::Map.new
      @resources = LRUHash.new
    end
  end

  THREAD_BULKHEAD_DISABLED_VAR = :semian_bulkheads_disabled
  private_constant(:THREAD_BULKHEAD_DISABLED_VAR)

  def bulkheads_disabled_in_thread?(thread)
    thread.thread_variable_get(THREAD_BULKHEAD_DISABLED_VAR)
  end

  def disable_bulkheads_for_thread(thread)
    old_value = thread.thread_variable_get(THREAD_BULKHEAD_DISABLED_VAR)
    thread.thread_variable_set(THREAD_BULKHEAD_DISABLED_VAR, true)
    yield
  ensure
    thread.thread_variable_set(THREAD_BULKHEAD_DISABLED_VAR, old_value)
  end

  def resources
    return @resources if defined?(@resources) && @resources

    @reset_mutex.synchronize do
      @resources ||= LRUHash.new
    end
  end

  def consumers
    return @consumers if defined?(@consumers) && @consumers

    @reset_mutex.synchronize do
      @consumers ||= Concurrent::Map.new
    end
  end

  private

  def create_adaptive_circuit_breaker(name, **options)
    return if ENV.key?("SEMIAN_CIRCUIT_BREAKER_DISABLED") || ENV.key?("SEMIAN_ADAPTIVE_CIRCUIT_BREAKER_DISABLED")

    # Fixed parameters based on design document recommendations
    AdaptiveCircuitBreaker.new(
      name: name,
      kp: 0.75, # Standard proportional gain
      ki: 0.01, # Moderate integral gain
      kd: 0.5, # Small derivative gain (as per design doc)
      window_size: 10, # 10-second window for rate calculation and update interval
      sliding_interval: 1, # 1-second interval for background health checks
      initial_history_duration: 900, # 15 minutes of initial history for p90 calculation
      initial_error_rate: options[:initial_error_rate] || 0.01, # 1% error rate for initial p90 calculation
      implementation: implementation(**options),
    )
  end

  def create_circuit_breaker(name, **options)
    return if ENV.key?("SEMIAN_CIRCUIT_BREAKER_DISABLED")
    return unless options.fetch(:circuit_breaker, true)

    exceptions = options[:exceptions] || []
    CircuitBreaker.new(
      name,
      success_threshold: options[:success_threshold],
      error_threshold: options[:error_threshold],
      error_threshold_timeout: options[:error_threshold_timeout],
      error_timeout: options[:error_timeout],
      error_threshold_timeout_enabled: if options[:error_threshold_timeout_enabled].nil?
                                         true
                                       else
                                         options[:error_threshold_timeout_enabled]
                                       end,
      lumping_interval: if options[:lumping_interval].nil?
                          0
                        else
                          options[:lumping_interval]
                        end,
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
    return if ENV.key?("SEMIAN_BULKHEAD_DISABLED") || bulkheads_disabled_in_thread?(Thread.current)
    return unless options.fetch(:bulkhead, true)

    permissions = options[:permissions] || default_permissions
    timeout = options[:timeout] || 0
    ::Semian::Resource.new(
      name,
      tickets: options[:tickets],
      quota: options[:quota],
      permissions: permissions,
      timeout: timeout,
    )
  end
end

if Semian.semaphores_enabled?
  require "semian/semian"
else
  Semian::MAX_TICKETS = 0
end

if defined? ActiveSupport
  ActiveSupport.on_load(:active_record) do
    require "semian/rails"
  end
end
