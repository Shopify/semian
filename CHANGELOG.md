# Unreleased

* Feature: Use prepend when monkey-patching Net::HTTP. (#157)
* Feature: Include time spend waiting for bulkhead in notification (#154)

# v0.7.1

*  Feature: Add the behaviour to enable open circuiting on 5xxs conditionally  (#149)
*  Refactor: Configurable hosts for Semian's development dependencies (#152)

# v0.7.0

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
