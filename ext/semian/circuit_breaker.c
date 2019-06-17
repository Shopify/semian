#include "circuit_breaker.h"

#include "sysv_semaphores.h"
#include "sysv_shared_memory.h"
#include "types.h"
#include "util.h"

void
semian_circuit_breaker_free(void* ptr)
{
  semian_circuit_breaker_t* res = (semian_circuit_breaker_t*)ptr;
  free_shared_memory(res->shmem);
}

size_t
semian_circuit_breaker_size(const void* ptr)
{
  return sizeof(semian_circuit_breaker_t);
}

static const rb_data_type_t semian_circuit_breaker_type = {
  .wrap_struct_name = "semian_circuit_breaker",
  .function = {
    .dmark = NULL,
    .dfree = semian_circuit_breaker_free,
    .dsize = semian_circuit_breaker_size,
  },
  .data = NULL,
  .flags = RUBY_TYPED_FREE_IMMEDIATELY,
};

void
Init_CircuitBreaker() {
  dprintf("Init_CircuitBreaker");

  VALUE cSemian = rb_const_get(rb_cObject, rb_intern("Semian"));
  VALUE cCircuitBreaker = rb_const_get(cSemian, rb_intern("CircuitBreaker"));

  rb_define_alloc_func(cCircuitBreaker, semian_circuit_breaker_alloc);
  rb_define_method(cCircuitBreaker, "initialize_circuit_breaker", semian_circuit_breaker_initialize, 1);
}

VALUE
semian_circuit_breaker_alloc(VALUE klass)
{
  semian_circuit_breaker_t *res;
  VALUE obj = TypedData_Make_Struct(klass, semian_circuit_breaker_t, &semian_circuit_breaker_type, res);
  return obj;
}

VALUE
semian_circuit_breaker_initialize(VALUE self, VALUE name)
{
  semian_circuit_breaker_t *res = NULL;
  TypedData_Get_Struct(self, semian_circuit_breaker_t, &semian_circuit_breaker_type, res);
  res->key = generate_key(to_s(name));

  dprintf("Initializing circuit breaker '%s' (key: %lu)", to_s(name), res->key);
  res->sem_id = initialize_single_semaphore(res->key, SEM_DEFAULT_PERMISSIONS);
  res->shmem = get_or_create_shared_memory(res->key, NULL);

  return self;
}
