## Semian [![Build Status](https://travis-ci.org/Shopify/semian.svg?branch=master)](https://travis-ci.org/Shopify/semian)

![](http://i.imgur.com/7Vn2ibF.png)

Semian is a library for controlling access to slow or unresponsive external
services to avoid cascading failures.

When services are down they typically fail fast with errors like `ECONNREFUSED`
and `ECONNRESET` which can be rescued in code. However, slow resources fail
slowly. The thread serving the request blocks until it hits the timeout for the
slow resource. During that time, the thread is doing nothing useful and thus the
slow resource has caused a cascading failure by occupying workers and therefore
losing capacity. **Semian is a library for failing fast in these situations,
allowing you to handle errors gracefully.** Semian does this by intercepting
resource access through heuristic patterns inspired by [Hystrix][hystrix] and
[Release It][release-it]:

* [**Circuit breaker**](#circuit-breaker). A pattern for limiting the
  amount of requests to a dependency that is having issues.
* [**Bulkheading**](#bulkheading). Controlling the concurrent access to
  a single resource, access is coordinates server-wide with [SysV
  semaphores][sysv].

Resource drivers are monkey-patched to be aware of Semian, these are called
[Semian Adapters](#adapters). Thus, every time resource access is requested
Semian is queried for status on the resource first.  If Semian, through the
patterns above, deems the resource to be unavailable it will raise an exception.
**The ultimate outcome of Semian is always an exception that can then be rescued
for a graceful fallback**. Instead of waiting for the timeout, Semian raises
straight away.

If you are already rescuing exceptions for failing resources and timeouts,
Semian is mostly a drop-in library with a little configuration that will make
your code more resilient to slow resource access. But, [do you even need
Semian?](#do-i-need-semian)

For an overview of building resilient Ruby applications, start by reading [the
Shopify blog post on Toxiproxy and Semian][resiliency-blog-post]. For more in
depth information on Semian, see [Understanding Semian](#understanding-semian).
Semian is an extraction from [Shopify][shopify] where it's been running
successfully in production since October, 2014.

The other component to your Ruby resiliency kit is [Toxiproxy][toxiproxy] to
write automated resiliency tests.

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

Semian works by intercepting resource access. Every time access is requested,
Semian is queried, and it will raise an exception if the resource is unavailable
according to the circuit breaker or bulkheads.  This is done by monkey-patching
the resource driver. **The exception raised by the driver always inherits from
the Base exception class of the driver**, meaning you can always simply rescue
the base class and catch both Semian and driver errors in the same rescue for
fallbacks.

The following adapters are in Semian and tested heavily in production, the
version is the version of the public gem with the same name:

* [`semian/mysql2`][mysql-semian-adapter] (~> 0.3.16)
* [`semian/redis`][redis-semian-adapter] (~> 3.2.1)
* [`semian/net_http`][nethttp-semian-adapter]

### Creating Adapters

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

#### Thread Safety

Semian's circuit breaker implementation is thread-safe by default as of
`v0.7.0`. If you'd like to disable it for performance reasons, pass
`thread_safety_disabled: true` to the resource options.

Bulkheads should be disabled (pass `bulkhead: false`) in a threaded environment
(e.g. Puma or Sidekiq), but can safely be enabled in non-threaded environments
(e.g. Resque and Unicorn). As described in this document, circuit breakers alone
should be adequate in most environments with reasonably low timeouts.

Internally, semian uses `SEM_UNDO` for several sysv semaphore operations:

* Acquire
* Worker registration
* Semaphore metadata state lock

The intention behind `SEM_UNDO` is that a semaphore operation is automatically undone when the process exits. This
is true even if the process exits abnormally - crashes, receives a `SIG_KILL`, etc, because it is handled by
the operating system and not the process itself.

If, however, a thread performs a semop, the `SEM_UNDO` is on its parent process. This means that the operation
*will not* be undone when the thread exits. This can result in the following unfavorable behavior when using
threads:

* Threads acquire a resource, but are killed and the resource ticket is never released. For a process, the
ticket would be released by `SEM_UNDO`, but since it's a thread there is the potential for ticket starvation.
This can result in deadlock on the resource.
* Threads that register workers on a resource but are killed and never unregistered. For a process, the worker
count would be automatically decremented by `SEM_UNDO`, but for threads the worker count will continue to increment,
only being undone when the parent process dies. This can cause the number of tickets to dramatically exceed the quota.
* If a thread acquires the semaphore metadata lock and dies before releasing it, semian will deadlock on anything
attempting to acquire the metadata lock until the thread's parent process exits. This can prevent the ticket count
from being updated.

Moreover, a strategy that utilizes `SEM_UNDO` is not compatible with a strategy that attempts to the semaphores tickets manually.
In order to support threads, operations that currently use `SEM_UNDO` would need to use no semaphore flag, and the calling process
will be responsible for ensuring that threads are appropriately cleaned up. It is still possible to implement this, but
it would likely require an in-memory semaphore managed by the parent process of the threads. PRs welcome for this functionality.

#### Quotas

You may now set quotas per worker:

```ruby
client = Redis.new(semian: {
  name: "inventory",
  quota: 0.5,
  success_threshold: 2,
  error_threshold: 4,
  error_timeout: 20
})

```

Per the above example, you no longer need to care about the number of tickets.

Rather, the tickets shall be computed as a proportion of the number of active workers.

In this case, we'd allow 50% of the workers on a particular host to connect to this redis resource.

**Note**:

- You must pass **exactly** one of ticket or quota.
- Tickets available will be the ceiling of the quota ratio to the number of workers
 - So, with one worker, there will always be a minimum of 1 ticket
- Workers in different processes will automatically unregister when the process exits.

#### Net::HTTP
For the `Net::HTTP` specific Semian adapter, since many external libraries may create
HTTP connections on the user's behalf, the parameters are instead provided
by associating callback functions with `Semian::NetHTTP`, perhaps in an initialization file.

##### Naming and Options
To give Semian parameters, assign a `proc` to `Semian::NetHTTP.semian_configuration`
that takes a two parameters, `host` and `port` like `127.0.0.1`,`443` or `github_com`,`80`,
and returns a `Hash` with configuration parameters as follows. The `proc` is used as a
callback to initialize the configuration options, similar to other adapters.

```ruby
SEMIAN_PARAMETERS = { tickets: 1,
                      success_threshold: 1,
                      error_threshold: 3,
                      error_timeout: 10 }
Semian::NetHTTP.semian_configuration = proc do |host, port|
  # Let's make it only active for github.com
  if host == "github.com" && port == "80"
    SEMIAN_PARAMETERS.merge(name: "github.com_80")
  else
    nil
  end
end

# Called from within API:
# semian_options = Semian::NetHTTP.semian_configuration("github.com", 80)
# semian_identifier = "nethttp_#{semian_options[:name]}"
```

The `name` should be carefully chosen since it identifies the resource being protected.
The `semian_options` passed apply to that resource. Semian creates the `semian_identifier`
from the `name` to look up and store changes in the circuit breaker and bulkhead states
and associate successes, failures, errors with the protected resource.

We only require that:
* the `semian_configuration` be **set only once** over the lifetime of the library
* the output of the `proc` be the same over time, that is, the configuration produced by
  each pair of `host`, `port` is **the same each time** the callback is invoked.

For most purposes, `"#{host}_#{port}"` is a good default `name`. Custom `name` formats
can be useful to grouping related subdomains as one resource, so that they all
contribute to the same circuit breaker and bulkhead state and fail together.

A return value of `nil` for `semian_configuration` means Semian is disabled for that
HTTP endpoint. This works well since the result of a failed Hash lookup is `nil` also.
This behavior lets the adapter default to whitelisting, although the
behavior can be changed to blacklisting or even be completely disabled by varying
the use of returning `nil` in the assigned closure.

##### Additional Exceptions
Since we envision this particular adapter can be used in combination with many
external libraries, that can raise additional exceptions, we added functionality to
expand the Exceptions that can be tracked as part of Semian's circuit breaker.
This may be necessary for libraries that introduce new exceptions or re-raise them.
Add exceptions and reset to the [`default`][nethttp-default-errors] list using the following:

```ruby
# assert_equal(Semian::NetHTTP.exceptions, Semian::NetHTTP::DEFAULT_ERRORS)
Semian::NetHTTP.exceptions += [::OpenSSL::SSL::SSLError]

Semian::NetHTTP.reset_exceptions
# assert_equal(Semian::NetHTTP.exceptions, Semian::NetHTTP::DEFAULT_ERRORS)
```
##### Mark Unsuccessful Responses as Failures
Unsuccessful responses (e.g. 5xx responses) do not raise exceptions, and as such are not marked as failures by default. The `open_circuit_server_errors` Semian configuration parameter may be set to enable this behaviour, to mark unsuccessful responses as failures as seen below:

```ruby
SEMIAN_PARAMETERS = { tickets: 1,
                      success_threshold: 1,
                      error_threshold: 3,
                      error_timeout: 10,
                      open_circuit_server_errors: true}
```



# Understanding Semian

Semian is a library with heuristics for failing fast. This section will explain
in depth how Semian works and which situations it's applicable for. First we
explain the category of problems Semian is meant to solve. Then we dive into how
Semian works to solve these problems.

## Do I need Semian?

Semian is not a trivial library to understand, introduces complexity and thus
should be introduced with care. Remember, all Semian does is raise exceptions
based on heuristics. It is paramount that you understand Semian before
including it in production as you may otherwise be surprised by its behaviour.

Applications that benefit from Semian are those working on eliminating SPOFs
(Single Points of Failure), and specifically are running into a wall regarding
slow resources. But it is by no means a magic wand that solves all your latency
problems by being added to your `Gemfile`. This section describes the types of
problems Semian solves.

If your application is multithreaded or evented (e.g. not Resque and Unicorn)
these problems are not as pressing. You can still get use out of Semian however.

### Real World Example

This is better illustrated with a real world example from Shopify. When you are
browsing a store while signed in, Shopify stores your session in Redis.
If Redis becomes unavailable, the driver will start throwing exceptions.
We rescue these exceptions and simply disable all customer sign in functionality
on the store until Redis is back online.

This is great if querying the resource fails instantly, because it means we fail
in just a single roundtrip of ~1ms. But if the resource is unresponsive or slow,
this can take as long as our timeout which is easily 200ms. This means every
request, even if it does rescue the exception, now takes an extra 200ms.
Because every resource takes that long, our capacity is also significantly
degraded. These problems are explained in depth in the next two sections.

With Semian, the slow resource would fail instantly (after a small amount of
convergence time) preventing your response time from spiking and not decreasing
capacity of the cluster.

If this sounds familiar to you, Semian is what you need to be resilient to
latency. You may not need the graceful fallback depending on your application,
in which case it will just result in an error (e.g. a `HTTP 500`) faster.

We will now examine the two problems in detail.

#### In-depth analysis of real world example

If a single resource is slow, every single request is going to suffer. We saw
this in the example before. Let's illustrate this more clearly in the following
Rails example where the user session is stored in Redis:

```ruby
def index
  @user = fetch_user
  @posts = Post.all
end

private
def fetch_user
  user = User.find(session[:user_id])
rescue Redis::CannotConnectError
  nil
end
```

Our code is resilient to a failure of the session layer, it doesn't `HTTP 500`
if the session store is unavailable (this can be tested with
[Toxiproxy][toxiproxy]). If the `User` and `Post` data store is unavailable, the
server will send back `HTTP 500`. We accept that, because it's our primary data
store. This could be prevented with a caching tier or something else out of
scope.

This code has two flaws however:

1. **What happens if the session storage is consistently slow?** I.e. the majority
   of requests take, say, more than half the timeout time (but it should only
   take ~1ms)?
2. **What happens if the session storage is unavailable and is not responding at
   all?** I.e. we hit timeouts on every request.

These two problems in turn have two related problems associated with them:
response time and capacity.

#### Response time

Requests that attempt to access a down session storage are all gracefully handled, the
`@user` will simply be `nil`, which the code handles. There is still a
major impact on users however, as every request to the storage has to time
out. This causes the average response time to all pages that access it to go up by
however long your timeout is. Your timeout is proportional to your worst case timeout,
as well as the number of attempts to hit it on each page. This is the problem Semian
solves by using heuristics to fail these requests early which causes a much better
user experience during downtime.

#### Capacity loss

When your single-threaded worker is waiting for a resource to return, it's
effectively doing nothing when it could be serving fast requests. To use the
example from before, perhaps some actions do not access the session storage at
all. These requests will pile up behind the now slow requests that are trying to
access that layer, because they're failing slowly. Essentially, your capacity
degrades significantly because your average response time goes up (as explained
in the previous section). Capacity loss simply follows from an increase in
response time. The higher your timeout and the slower your resource, the more
capacity you lose.

#### Timeouts aren't enough

It should be clear by now that timeouts aren't enough. Consistent timeouts will
increase the average response time, which causes a bad user experience, and
ultimately compromise the performance of the entire system. Even if the timeout
is as low as ~250ms (just enough to allow a single TCP retransmit) there's a
large loss of capacity and for many applications a 100-300% increase in average
response time. This is the problem Semian solves by failing fast.

## How does Semian work?

Semian consists of two parts: circuit breaker and bulkheading. To understand
Semian, and especially how to configure it, we must understand these patterns
and their implementation.

### Circuit Breaker

The circuit breaker pattern is based on a simple observation - if we hit a
timeout or any other error for a given service one or more times, we’re likely
to hit it again for some amount of time. Instead of hitting the timeout
repeatedly, we can mark the resource as dead for some amount of time during
which we raise an exception instantly on any call to it. This is called the
[circuit breaker pattern][cbp].

![](http://cdn.shopify.com/s/files/1/0070/7032/files/image01_grande.png)

When we perform a Remote Procedure Call (RPC), it will first check the circuit.
If the circuit is rejecting requests because of too many failures reported by
the driver, it will throw an exception immediately. Otherwise the circuit will
call the driver. If the driver fails to get data back from the data store, it
will notify the circuit. The circuit will count the error so that if too many
errors have happened recently, it will start rejecting requests immediately
instead of waiting for the driver to time out. The exception will then be raised
back to the original caller. If the driver’s request was successful, it will
return the data back to the calling method and notify the circuit that it made a
successful call.

The state of the circuit breaker is local to the worker and is not shared across
all workers on a server.

#### Circuit Breaker Configuration

There are three configuration parameters for circuit breakers in Semian:

* **error_threshold**. The amount of errors to encounter for the worker before
  opening the circuit, that is to start rejecting requests instantly.
* **error_timeout**. The amount of time until trying to query the resource
  again.
* **success_threshold**. The amount of successes on the circuit until closing it
  again, that is to start accepting all requests to the circuit.

### Bulkheading

For some applications, circuit breakers are not enough. This is best illustrated
with an example. Imagine if the timeout for our data store isn't as low as
200ms, but actually 10 seconds. For example, you might have a relational data
store where for some customers, 10s queries are (unfortunately) legitimate.
Reducing the time of worst case queries requires a lot of effort. Dropping the
query immediately could potentially leave some customers unable to access
certain functionality. High timeouts are especially critical in a non-threaded
environment where blocking IO means a worker is effectively doing nothing.

In this case, circuit breakers aren't sufficient. Assuming the circuit is shared
across all processes on a server, it will still take at least 10s before the
circuit is open. In that time every worker is blocked (see also "Defense Line"
section for an in-depth explanation of the co-operation between circuit breakers
and bulkheads) this means we're at reduced capacity for at least 20s, with the
last 10s timeouts occurring just before the circuit opens at the 10s mark when a
couple of workers have hit a timeout and the circuit opens. We thought of a
number of potential solutions to this problem - stricter timeouts, grouping
timeouts by section of our application, timeouts per statement—but they all
still revolved around timeouts, and those are extremely hard to get right.

Instead of thinking about timeouts, we took inspiration from Hystrix by Netflix
and the book Release It (the resiliency bible), and look at our services as
connection pools. On a server with `W` workers, only a certain number of them
are expected to be talking to a single data store at once. Let's say we've
determined from our monitoring that there’s a 10% chance they’re talking to
`mysql_shard_0` at any given point in time under normal traffic. The probability
that five workers are talking to it at the same time is 0.001%. If we only allow
five workers to talk to a resource at any given point in time, and accept the
0.001% false positive rate—we can fail the sixth worker attempting to check out
a connection instantly. This means that while the five workers are waiting for a
timeout, all the other `W-5` workers on the node will instantly be failing on
checking out the connection and opening their circuits. Our capacity is only
degraded by a relatively small amount.

We call this limitation primitive "tickets". In this case, the resource access
is limited to 5 tickets (see Configuration). The timeout value specifies the
maximum amount of time to block if no ticket is available.

How do we limit the access to a resource for all workers on a server when the
workers do not directly share memory? This is implemented with [SysV
semaphores][sysv] to provide server-wide access control.

#### Bulkhead Configuration

There are two configuration values. It's not easy to choose good values and we're
still experimenting with ways to figure out optimal ticket numbers. Generally
something below half the number of workers on the server for endpoints that are
queried frequently has worked well for us.

* **tickets**. Number of workers that can concurrently access a resource.
* **timeout**. Time to wait to acquire a ticket if there are no tickets left.
  We recommend this to be `0` unless you have very few workers running (i.e.
  less than ~5).

Note that there are system-wide limitations on how many tickets can be allocated
on a system. `cat /proc/sys/kernel/sem` will tell you.

> System-wide limit on the number of semaphore sets.  On Linux
  systems before version 3.19, the default value for this limit
  was 128.  Since Linux 3.19, the default value is 32,000.  On
  Linux, this limit can be read and modified via the fourth
  field of `/proc/sys/kernel/sem`.

## Defense line

The finished defense line for resource access with circuit breakers and
bulkheads then looks like this:

![](http://cdn.shopify.com/s/files/1/0070/7032/files/image02_grande.png)

The RPC first checks the circuit; if the circuit is open it will raise the
exception straight away which will trigger the fallback (the default fallback is
a 500 response). Otherwise, it will try Semian which fails instantly if too many
workers are already querying the resource. Finally the driver will query the
data store. If the data store succeeds, the driver will return the data back to
the RPC. If the data store is slow or fails, this is our last line of defense
against a misbehaving resource. The driver will raise an exception after trying
to connect with a timeout or after an immediate failure. These driver actions
will affect the circuit and Semian, which can make future calls fail faster.

A useful way to think about the co-operation between bulkheads and circuit
breakers is through visualizing a failure scenario graphing capacity as a
function of time. If an incident strikes that makes the server unresponsive
with a `20s` timeout on the client and you only have circuit breakers
enabled--you will lose capacity until all workers have tripped their circuit
breakers. The slope of this line will depend on the amount of traffic to the now
unavailable service. If the slope is steep (i.e. high traffic), you'll lose
capacity quicker. The higher the client driver timeout, the longer you'll lose
capacity for. In the example below we have the circuit breakers configured to
open after 3 failures:

![resiliency- circuit breakers](https://cloud.githubusercontent.com/assets/97400/22405538/53229758-e612-11e6-81b2-824f873c3fb7.png)

If we imagine the same scenario but with _only_ bulkheads, configured to have
tickets for 50% of workers at any given time, we'll see the following
flat-lining scenario:

![resiliency- bulkheads](https://cloud.githubusercontent.com/assets/97400/22405542/6832a372-e612-11e6-88c4-2452b64b3121.png)

Circuit breakers have the nice property of re-gaining 100% capacity. Bulkheads
have the desirable property of guaranteeing a minimum capacity. If we do
addition of the two graphs, marrying bulkheads and circuit breakers, we have a
plummy outcome:

![resiliency- circuit breakers bulkheads](https://cloud.githubusercontent.com/assets/97400/22405550/a25749c2-e612-11e6-8bc8-5fe29e212b3b.png)

This means that if the slope or client timeout is sufficiently low, bulkheads
will provide little value and are likely not necessary.

## Failing gracefully

Ok, great, we've got a way to fail fast with slow resources, how does that make
my application more resilient?

Failing fast is only half the battle. It's up to you what you do with these
errors, in the [session example](#real-world-example) we handle it gracefully by
signing people out and disabling all session related functionality till the data
store is back online. However, not rescuing the exception and simply sending
`HTTP 500` back to the client faster will help with [capacity
loss](#capacity-loss).

### Exceptions inherit from base class

It's important to understand that the exceptions raised by [Semian
Adapters](#adapters) inherit from the base class of the driver itself, meaning
that if you do something like:

```ruby
def posts
  Post.all
rescue Mysql2::Error
  []
end
```

Exceptions raised by Semian's `MySQL2` adapter will also get caught.

### Patterns

We do not recommend mindlessly sprinkling `rescue`s all over the place. What you
should do instead is writing decorators around secondary data stores (e.g. sessions)
that provide resiliency for free. For example, if we stored the tags associated
with products in a secondary data store it could look something like this:

```ruby
# Resilient decorator for storing a Set in Redis.
class RedisSet
  def initialize(key)
    @key = key
  end

  def get
    redis.smembers(@key)
  rescue Redis::BaseConnectionError
    []
  end

  private

  def redis
    @redis ||= Redis.new
  end
end

class Product
  # This will simply return an empty array in the case of a Redis outage.
  def tags
    tags_set.get
  end

  private

  def tags_set
    @tags_set ||= RedisSet.new("product:tags:#{self.id}")
  end
end
```

These decorators can be resiliency tested with [Toxiproxy][toxiproxy]. You can
provide fallbacks around your primary data store as well. In our case, we simply
`HTTP 500` in those cases unless it's cached because these pages aren't worth
much without data from their primary data store.

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

# FAQ

**How does Semian work with containers?** Semian uses [SysV semaphores][sysv] to
coordinate access to a resource. The semaphore is only shared within the
[IPC][namespaces]. Unless you are running many workers inside every container,
this leaves the bulkheading pattern effectively useless. We recommend sharing
the IPC namespace between all containers on your host for the best ticket
economy. If you are using Docker, this can be done with the [--ipc
flag](https://docs.docker.com/reference/run/#ipc-settings).

**Why isn't resource access shared across the entire cluster?** This implies a
coordination data store. Semian would have to be resilient to failures of this
data store as well, and fall back to other primitives. While it's nice to have
all workers have the same view of the world, this greatly increases the
complexity of the implementation which is not favourable for resiliency code.

**Why isn't the circuit breaker implemented as a host-wide mechanism?** No good
reason. Patches welcome!

**Why is there no fallback mechanism in Semian?** Read the [Failing
Gracefully](#failing-gracefully) section. In short, exceptions is exactly this.
We did not want to put an extra level on abstraction on top of this. In the
first internal implementation this was the case, but we later moved away from
it.

**Why does it not use normal Ruby semaphores?** To work properly the access
control needs to be performed across many workers. With MRI that means having
multiple processes, not threads. Thus we need a primitive outside of the
interpreter. For other Ruby implementations a driver that uses Ruby semaphores
could be used (and would be accepted as a PR).

**Why are there three semaphores in the semaphore sets for each resource?** This
has to do with being able to resize the number of tickets for a resource online.

**Can I change the number of tickets freely?** Yes, the logic for this isn't
trivial but it works well.

**What is the performance overhead of Semian?** Extremely minimal in comparison
to going to the network. Don't worry about it unless you're instrumenting
non-IO.

[hystrix]: https://github.com/Netflix/Hystrix
[release-it]: https://pragprog.com/book/mnee/release-it
[shopify]: http://www.shopify.com/
[mysql-semian-adapter]: lib/semian/mysql2.rb
[redis-semian-adapter]: lib/semian/redis.rb
[semian-adapter]: lib/semian/adapter.rb
[nethttp-semian-adapter]: lib/semian/net_http.rb
[nethttp-default-errors]: lib/semian/net_http.rb#L35-L45
[semian-instrumentable]: lib/semian/instrumentable.rb
[statsd-instrument]: http://github.com/shopify/statsd-instrument
[resiliency-blog-post]: http://www.shopify.com/technology/16906928-building-and-testing-resilient-ruby-on-rails-applications
[toxiproxy]: https://github.com/Shopify/toxiproxy
[sysv]: http://man7.org/linux/man-pages/man7/svipc.7.html
[cbp]: https://en.wikipedia.org/wiki/Circuit_breaker_design_pattern
[namespaces]: http://man7.org/linux/man-pages/man7/namespaces.7.html
