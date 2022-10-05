# Unreleased

# v0.16.0

* Typo in error message for missing option `:tickets`. (#412)
* Add process id in DEBUG message for bulkheading/resource. (#416)
* Feature: Add ability to turn off window based circuit eviction (#418)

# v0.15.0

* Pinging a closed connection shouldn't be considered a failure. (#396)
* Fix: Patch `new_client` for Rails apps so that the OpenCircuitError makes it through. (#395)

# v0.14.0

* Compatible with Redis 5 (#388, #392)

# v0.13.3

* Add a warning message about redis 5.x. (#386)

# v0.13.2

* Fix: Update AbstractAdapter patch to accomodate recent Rails changes. (#364)

# v0.13.1

* Fix: Raise `Redis::OutOfMemoryError` for messages that match `OOM command not allowed when used memory > 'maxmemory'` rather than checking `start_with?("OOM ")`. (#367)

# v0.13.0

* Refactor: Replace Time.now with CLOCK_MONOTONIC in MockServer (#318)
* Fix: Circuit not open for GRPC::ActiveCall::Operation failures (#348)

# v0.12.0

* Feature: Add support for the `redis-client` gem (#314)

# v0.11.8

* Feature: Add error_threshold_timeout configuration parameter (#299)

# v0.11.7

* Fix: ECONNRESET won't trigger circuit open for redis (#306)

# v0.11.6

* Fix: pass disable flag by patching new singleton method (#303)

# v0.11.5

* Feature: Add disable flag to http adapter (#301)

# v0.11.4

* Fix: Add `extern` to global variable declarations for gcc 10 (#288)

# v0.11.3

* Feature: Log last error message on circuit breaker state transition (#285)
* Fix: Update README and docs to resolve common misconception about error_threshold (#283)

# v0.11.2

* Fix: Remove `MySQL client is not connected` error from mysql2 adapter

# v0.11.1

* Feature: Add `Semian.namespace` to globally prefix all the semaphore names. (#280)

# v0.11.0

* Feature: Add `Semian.default_permissions` to globally change the default semaphore permissions. (#279)

# v0.10.6

* Fix: Match whitelisted SQL queries when Marginalia is prepended (#276)

# v0.10.5

* Fix: Compatibility with GC.compact

# v0.10.4

* Fix: Revert the changes in v0.10.3. (#270)

# v0.10.3

* Fix: Positional/Keyword arguments deprecations warning for Ruby 2.7 in the grpc adapter. (#269)

# v0.10.2

* Fix: Positional/Keyword arguments deprecations warning for Ruby 2.7.

# v0.10.1

* Fix: thread safety bug on Ruby 2.7. (#263)

# v0.10.0

* Feature: Support half open resource timeout for redis.

# v0.9.1

* Fix: Compatibility with MRI 2.3

# v0.9.0

* Feature: Add a LRU to garbage collect old resources. (#193)

# v0.8.9
* Fix: Recursion issue in MySQL2 adapter causing circuits breakers to stay open much longer than they should. (#250)
* Fix: Better handle DNS resolutions exceptions in Redis adapter. (#230)

# v0.8.8
* Feature: Introduce the GRPC adapter (#200)

# v0.8.7
* Fix: Instrument success for `acquire_circuit_breaker` (#209)

# v0.8.6
* Feature: If an error instance responds to `#marks_semian_circuits?` don't mark the circuit if it returns false (#210)

# v0.8.5
* Fix: Redis adapter using hiredis is resilient to DNS resolution failures (#205)

# v0.8.4
* Feature: Introduce `half_open_resource_timeout` which changes the resource timeout when the circuit is in a half-open state for the Net::HTTP adapter. (#198)
* Feature: Add the cause of the last error when a circuit opens (#197)
* Fix: Reset successes when transitioning to the half open state (#192)

# v0.8.1

* Fix: Expose `half_open?` when the circuit state has not transitioned but will. This allows consumers further up the stack to know if the circuit
is half open.

# v0.8.0

* Feature: Introduce `half_open_resource_timeout` which changes the resource timeout when the circuit is in a half-open state (#188)

# v0.7.8

* Feature: More informative error messages when initializing Semian with missing
  arguments (#182)
* Fix: Redis adapter is now resilient to DNS resolution failures (#184)

# v0.7.5

* Fix: Repaired compatibility with dependent Redis library

# v0.7.4

* Fix: Protect internal semaphore when adjusting resource count (#164)
* Feature: Use prepend when monkey-patching Net::HTTP. (#157)
* Feature: Include time spend waiting for bulkhead in notification (#154)

# v0.7.1

*  Feature: Add the behaviour to enable open circuiting on 5xxs conditionally  (#149)
*  Refactor: Configurable hosts for Semian's development dependencies (#152)

# v0.7.0

This change introduced a series of changes to support a new "dynamic quota" ticket
allocation strategy. This code primarily affects bulkheads (protected resources).

Rather than statically setting a ticket count, workers (in their own process) now register
themselves. By specifying 'quota' instead of 'tickets', the bulkhead threshold will now be
computed dynamically as a ratio of the number of registered workers, eliminating the need to
continuously readjust ticket counts, and supporting environments with non-uniform worker
distribution between machines.

* Feature: Support quota based allocation strategy (#120)
* Feature: Add ability to manually unregister workers (#130)
* Feature: Add ability to clear resources from adapters and unregister all resources (#134)
* Feature: Allow sysV IPC key to be accessed in ruby (#136)
* Feature: Expose registered worker count to ruby (#137)
* Refactor: Allow registered worker count to be accessed through bulkhead (#138)
* Bug fix: Register all workers (#128)
* Bug fix: Lazy instantiate redis clien on first I/O (#132)
* Bug fix: New mysql error (#131)
* Bug fix: Prevent race conditions when unregistering (#141)
* Refactor/Feature: Break coupling between resource and circuit breaker (#123)
* Refactor: Use generic max_sem_val (#117)
* Refactor: Fix header syntax (#118)
* Refactor: Always acquire semaphore without_gvl (#121)
* Thread-safety for circuit breakers by default (#150)
* Fix bug where calling name on a protected resource without a semaphore would fail (#151)

# v0.6.2

*  Refactor: Refactor semian ticket management into its own files (#116)
*  Refactor: Create sem_meta_lock and sem_meta_unlock (#115)
*  Refactor: Refactor semaphore operations (#114)

# v0.6.1

* Refactor: Generate a unique semaphore key by including size of semaphore set
* Refactor: Refactor semian\_resource related C functions
* Fix: Don't require sudo for travis (#110)
* Refactor: Refactor semian.c includes and types into header files
* Fix: Use glob instead of git for gemspec file list
* Fix: Fix travis CI for ruby 2.3.0 installing rainbows
* Refactor: Switch to enumerated type for tracking semaphore indices
* Docs: readme: explain co-operation between cbs and bulkheads
* Docs: readme: add section about server limits

# v0.6.0

* Feature: Load semian/rails automatically if necessary
* Feature: Implement AR::AbstractAdapter#semian\_resource

# v0.5.4

* Fix: Also let "Too many connections" be a first class conn error

# v0.5.3

* Fix: mysql: protect pings
* Fix: mysql: match more lost conn queries

# v0.5.2

* Fix: Make request\_allowed? thread safe
* Fix: Fix CI connect errors on HTTP requests by using 127.0.0.1 for host

# v0.5.1

* Fix: Assert Resource#initialize\_semaphore contract on Resource init
* Fix: Lock on older thin version for pre MRI 2.2 compatibility

# v0.5.0

* Fix: Only issue unsupported or disabled semaphores warnings when the first resource is instanciated
* Refactor: Cleanup requires
* Maintenance: Use published version of the toxiproxy gem
* Fix: Fix minitest deprecation warnings
* Maintenance: Update bundler on travis
* Maintenance: Update supported MRI versions on travis

# v0.4.3

* Fix: Fix lazy aliasing of Redis#semian\_resource
* Fix: Workaround rubocop parser limitations

# v0.4.2

* Fix: Fix for TimeoutError is deprecated in Ruby 2.3.0
* Feature: Include Ruby 2.3 in Travis builds

# v0.4.1
* Fix: resource: cast float ticket count to fixnum #75

# v0.4.0

* Feature: net/http: add adapter for net/http #58
* Refactor: circuit_breaker: split circuit breaker into three data structures to allow for
  alternative implementations in the future #62
* Fix: mysql: don't prevent rollbacks on transactions #60
* Fix: core: fix initialization bug when the resource is accessed before the options
  are set #65
