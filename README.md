## Semian [![Build Status](https://travis-ci.org/Shopify/semian.svg?branch=master)](https://travis-ci.org/Shopify/semian)

Semian is a Ruby implementation of the Bulkhead resource isolation pattern,
using SysV semaphores. Bulkheading controls access to external resources,
protecting against resource or network latency, by allowing otherwise slow
queries to fail fast.

Downtime is easy to detect. Requests fail when querying the resource, usually
fast. Reliably detecting higher than normal latency is more difficult. Strict
timeouts is one solution, but picking those are hard and usually needs to be
done per query or section of your application.

Semian takes a different approach. Instead of asking the question: "How long can
my query execute?" it raises the question "How long do I want to wait before
starting to execute my query?".

Imagine that your database is very slow. Requests that hit the slow database are
processed in your workers and end up timing out at the worker level. However,
other requests don't touch the slow database. These requests will start to queue
up behind the requests to the slow database, possibly never being served
because the client disconnects due to slowness. You're now effectively down,
because a single external resource is slow.

Semian solves this problem with resource tickets. Every time a worker addresses
an external resource, it takes a ticket for the duration of the query.  When the
query returns, it puts the ticket back into the pool. If you have `n` tickets,
and the `n + 1` worker tries to acquire a ticket to query the resource it'll
wait for `timeout` seconds to see if a ticket comes available, otherwise it'll
raise `Semian::TimeoutError`. 

By failing fast, this solves the problem of one slow database taking your
platform down. The busyness of the external resource determines the `timeout`
and ticket count. You can also rescue `Semian::TimeoutError` to provide fallback
values, such as showing an error message to the user.

A subset of workers will still be tied up on the slow database, meaning you are
under capacity with a slow external resource. However, at most you'll have
`ticket count` workers occupied. This is a small price to pay. By implementing
the circuit breaker pattern on top of Semian, you can avoid that. That may be
built into Semian in the future.

Under the hood, Semian is implemented with SysV semaphores. In a threaded web
server, the semaphore could be in-process. Semian was written with forked web
servers in mind, such as Unicorn, but Semian can be used perfectly fine in a
threaded web server.

### Usage

In a master process, register a resource with a specified number of tickets
(number of concurrent clients):

```ruby
Semian.register(:mysql_master tickets: 3, timeout: 0.5, error_threshold: 3, error_timeout: 10, success_threshold: 2)
```

Then in your child processes, you can use the resource:

```ruby
Semian[:mysql_master].acquire do
  # Query the database. If three other workers are querying this resource at the
  # same time, this block will block for up to 0.5s waiting for another worker
  # to release a ticket. Otherwise, it'll raise `Semian::TimeoutError`.
end
```

If you have a process that doesn't `fork`, you can still use the same namespace
to control access to a shared resource:

```ruby
Semian.register(:mysql_master, timeout: 0.5)

Semian[:mysql_master].acquire do
  # Query the resource
end
```

### Install

In your Gemfile:

```ruby
gem "semian"
```
