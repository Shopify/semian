# v0.4.0

* net/http: add adapter for net/http #58
* circuit_breaker: split circuit breaker into three data structures to allow for
  alternative implementations in the future #62
* mysql: don't prevent rollbacks on transactions #60
* core: fix initialization bug when the resource is accessed before the options
  are set #65
