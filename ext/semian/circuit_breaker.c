#include "circuit_breaker.h"

#include <errno.h>
#include <sys/ipc.h>
#include <sys/shm.h>
#include "types.h"
#include "util.h"

static const rb_data_type_t semian_circuit_breaker_type;

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
  dprintf("semian_circuit_breaker_alloc");

  semian_circuit_breaker_t *res;
  VALUE obj = TypedData_Make_Struct(klass, semian_circuit_breaker_t, &semian_circuit_breaker_type, res);
  return obj;
}

VALUE
semian_circuit_breaker_initialize(VALUE self, VALUE id)
{
  const char *c_id_str = check_id_arg(id);
  dprintf("semian_circuit_breaker_initialize('%s')", c_id_str);

  // Build semian resource structure
  semian_circuit_breaker_t *res = NULL;
  TypedData_Get_Struct(self, semian_circuit_breaker_t, &semian_circuit_breaker_type, res);

  // Initialize the semaphore set
  // initialize_semaphore_set(res, c_id_str, c_permissions, c_tickets, c_quota);
  res->name = strdup(c_id_str);

  key_t key = generate_key(res->name);
  dprintf("Creating shared memory for '%s' (id %u)", res->name, key);
  const int permissions = 0664;
  int shmid = shmget(key, 1024, IPC_CREAT | permissions);
  if (shmid == -1) {
    rb_raise(rb_eArgError, "could not create shared memory (%s)", strerror(errno));
  }

  dprintf("Getting shared memory (id %u)", shmid);
  void *val = shmat(shmid, NULL, 0);
  if (val == (void*)-1) {
    rb_raise(rb_eArgError, "could not get shared memory (%s)", strerror(errno));
  }

  semian_circuit_breaker_shared_t *data = (semian_circuit_breaker_shared_t*)val;
  if (data == NULL) {
    rb_raise(rb_eArgError, "could not get shared memory (%s)", strerror(errno));
  }

  dprintf("successes = %d", data->successes);
  data->successes = 0;

  return self;
}
