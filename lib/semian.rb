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
# A resource is registered by using the Semian.register method.
#
# ==== Examples
#
# ===== Registering a resource
#
#    Semian.register :mysql_shard0, tickets: 10, timeout: 0.5
#
# This registers a new resource called <code>:mysql_shard0</code> that has 10 tickets andd a default timeout of 500 milliseconds.
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
class Semian
  class << self
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
    # Returns the registered resource.
    def register(name, tickets: 0, permissions: 0660, timeout: 1)
      raise ArgumentError.new("Name (#{name.inspect}) must be able to be cast to a symbol (#to_sym)") unless name.respond_to?(:to_sym)
      resource = Resource.new(name.to_sym, tickets, permissions, timeout)
      resources[name.to_sym] = resource
    end

    # Retrieves a resource by name.
    def [](name)
      resources[name.to_sym]
    end

    # Retrieves a hash of all registered resources.
    def resources
      @resources ||= {}
    end
  end
end

require 'semian/platform'
if Semian.supported_platform?
  require 'semian/semian'
else
  require 'semian/unsupported'
  $stderr.puts "Semian is not supported on #{RUBY_PLATFORM} - all operations will no-op"
end
require 'semian/version'
