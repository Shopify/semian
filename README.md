## Semian [![Build Status](https://travis-ci.org/Shopify/semian.svg?branch=master)](https://travis-ci.org/Shopify/semian)

Semian is a latency and fault tolerance library for protecting your Ruby
applications against misbehaving external services. It allows you to fail fast
so you can handle errors gracefully. The patterns are inspired by
[Hystrix][hystrix] and [Release It][release-it]. Semian is an extraction from
[Shopify][shopify] where it's been running successfully in production since
October, 2014.

For an overview of building resilient Ruby application, see [the blog post on
Toxiproxy and Semian][resiliency-blog-post]. We recommend using
[Toxiproxy][toxiproxy] to test for resiliency.

# Usage

Install by adding the gem to your `Gemfile` and require the [adapters](#adapters) you need:

```ruby
gem 'semian', require: %w(semian semian/mysql2 semian/redis)
```

We recommend this pattern of requiring adapters directly from the `Gemfile`.
This makes ensures Semian adapters is loaded as early as possible, to also
protect your application during boot. Please see the [adapter configuration
section](#configuration) on how to configure adapters.

## Adapters

The following adapters are in Semian and work against the public gems:

* [`semian/mysql2`][mysql-semian-adapter] (~> 0.3.16)
* [`semian/redis`][redis-semian-adapter] (~> 3.2.1)

### Configuration

When instantiating a resource it now needs to be configured for Semian. This is
done by passing `semian` as an argument when initializing the client. Examples
built in adapters:

```ruby
# MySQL2 client
# In Rails this means having a Semian key in database.yml for each db.
client = Mysql2::Client.new(host: "localhost", username: "root", semian: {
  name: "master",
  tickets: 8, # See the Understanding Semian section on picking these values
  success_threshold: 2,
  error_threshold: 3,
  error_timeout: 10
})

# Redis client
client = Redis.new(semian: {
  name: "inventory",
  tickets: 4,
  success_threshold: 2,
  error_threshold: 4,
  error_timeout: 20
})
```

### Creating an adapter

To create a Semian adapter you must implement the following methods:

1. [`include Semian::Adapter`][semian-adapter]. Use the helpers to wrap the
   resource. This takes care of situations such as monitoring, nested resources,
   unsupported platforms, creating the Semian resource if it doesn't already
   exist and so on.
2. `#semian_identifier`. This is responsible for returning a symbol that
   represents every unique resource, for example `redis_master` or
   `mysql_shard_1`. This is usually assembled from a `name` attribute on the
   Semian configuration hash, but could also be `<host>:<port>`.
3. `connect`. The name of this method varies. You must override the driver's
   connect method with one that wraps the connect call with
   `Semian::Resource#acquire`. You should do this at the lowest possible level.
4. `query`. Same as `connect` but for queries on the resource.
5. Define exceptions `ResourceBusyError` and `CircuitOpenError`. These are
   raised when the request was rejected early because the resource is out of
   tickets or because the circuit breaker is open (see [Understanding
   Semian](#understanding-semian). They should inherit from the base exception
   class from the raw driver. For example `Mysql2::Error` or
   `Redis::BaseConnectionError` for the MySQL and Redis drivers. This makes it
   easy to `rescue` and handle them gracefully in application code, by
   `rescue`ing the base class.

The best resource is looking at the [already implemented adapters](#adapters).

## Monitoring

With [`Semian::Instrumentable`][semian-instrumentable] clients can monitor
Semian internals. For example to instrument just events with
[`statsd-instrument`][statsd-instrument]:

```ruby
# `event` is `success`, `busy`, `circuit_open`.
# `resource` is the `Semian::Resource` object
# `scope` is `connection` or `query` (others can be instrumented too from the adapter)
# `adapter` is the name of the adapter (mysql2, redis, ..)
Semian.subscribe do |event, resource, scope, adapter|
  StatsD.increment("Shopify.#{adapter}.semian.#{event}", 1, tags: [
    "resource:#{resource.name}",
    "total_tickets:#{resource.tickets}",
    "type:#{scope}",
  ])
end
```

# Understanding Semian

Coming soon!

[hystrix]: https://github.com/Netflix/Hystrix
[release-it]: https://pragprog.com/book/mnee/release-it
[shopify]: http://www.shopify.com/
[mysql-semian-adapter]: https://github.com/Shopify/semian/blob/master/lib/semian/mysql2.rb
[redis-semian-adapter]: https://github.com/Shopify/semian/blob/master/lib/semian/redis.rb
[semian-adapter]: https://github.com/Shopify/semian/blob/master/lib/semian/adapter.rb
[semian-instrumentable]: https://github.com/Shopify/semian/blob/master/lib/semian/instrumentable.rb
[statsd-instrument]: http://github.com/shopify/statsd-instrument
[resiliency-blog-post]: http://www.shopify.com/technology/16906928-building-and-testing-resilient-ruby-on-rails-applications
[toxiproxy]: https://github.com/Shopify/toxiproxy
