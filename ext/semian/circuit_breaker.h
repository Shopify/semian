#ifndef CIRCUIT_BREAKER_H
#define CIRCUIT_BREAKER_H

#include <ruby.h>

void Init_CircuitBreaker();

VALUE semian_circuit_breaker_alloc(VALUE klass);
VALUE semian_circuit_breaker_initialize(VALUE self, VALUE id);
VALUE semian_circuit_breaker_successes(VALUE self);

#endif // CIRCUIT_BREAKER_H