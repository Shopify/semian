## Semian

Inspired by the bulkhead resource isolation pattern used in [Hystrix](https://github.com/Netflix/Hystrix/wiki/How-it-Works#Isolation), Semian aims to provide a Ruby API that can be used to control access to external resources.

This can be used with a forking Ruby application server like Unicorn to prevent app server starvation when a resource is slow or not responding.

### Usage

In a master process, register a resource with a specified number of tickets (number of concurrent clients):
```ruby
require 'semian'

Semian.register(:mysql_master, tickets: 3, timeout: 0.5)
```

Then in your child processes, you can use the resource:
```ruby
Semian[:mysql_master].acquire do
	# Query mysql and do things
end
```

If you have a process that does not fork, you can still use the same namespace to control access to a shared resource:
```ruby
Semian.register(:mysql_master, timeout: 0.5)
Semian[:mysql_master].acquire do
	# Query mysql and do things
end
```
