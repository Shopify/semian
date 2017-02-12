#include <semian_resource.h>

/*
 * call-seq:
 *    resource.acquire(timeout: default_timeout) { ... }  -> result of the block
 *
 * Acquires a resource. The call will block for <code>timeout</code> seconds if a ticket
 * is not available. If no ticket is available within the timeout period, Semian::TimeoutError
 * will be raised.
 *
 * If no timeout argument is provided, the default timeout passed to Semian.register will be used.
 *
 */
// EXPORTED
VALUE
semian_resource_acquire(int argc, VALUE *argv, VALUE self)
{
  semian_resource_t *self_res = NULL;
  semian_resource_t res = { 0 };

  if (!rb_block_given_p()) {
    rb_raise(rb_eArgError, "acquire requires a block");
  }

  TypedData_Get_Struct(self, semian_resource_t, &semian_resource_type, self_res);
  res = *self_res;

  if (res.quota > 0) {
    // Ensure that configured tickets matches quota before acquiring
    sem_meta_lock(res.sem_id);
    update_tickets_from_quota(res.sem_id, res.quota);
    sem_meta_unlock(res.sem_id);
  }

  /* allow the default timeout to be overridden by a "timeout" param */
  if (argc == 1 && TYPE(argv[0]) == T_HASH) {
    VALUE timeout = rb_hash_aref(argv[0], ID2SYM(id_timeout));
    if (TYPE(timeout) != T_NIL) {
      if (TYPE(timeout) != T_FLOAT && TYPE(timeout) != T_FIXNUM) {
        rb_raise(rb_eArgError, "timeout parameter must be numeric");
      }
      ms_to_timespec(NUM2DBL(timeout) * 1000, &res.timeout);
    }
  } else if (argc > 0) {
    rb_raise(rb_eArgError, "invalid arguments");
  }

  /* release the GVL to acquire the semaphore */
  WITHOUT_GVL(acquire_semaphore_without_gvl, &res, RUBY_UBF_IO, NULL);
  if (res.error != 0) {
    if (res.error == EAGAIN) {
      rb_raise(eTimeout, "timed out waiting for resource '%s'", res.name);
    } else {
      raise_semian_syscall_error("semop()", res.error);
    }
  }

  return rb_ensure(rb_yield, self, cleanup_semian_resource_acquire, self);
}

// PRIVATE
VALUE
cleanup_semian_resource_acquire(VALUE self)
{
  semian_resource_t *res = NULL;
  TypedData_Get_Struct(self, semian_resource_t, &semian_resource_type, res);
  if (perform_semop(res->sem_id, SI_SEM_TICKETS, 1, SEM_UNDO, NULL) == -1) {
    res->error = errno;
  }
  return Qnil;
}

/*
 * call-seq:
 *   resource.destroy() -> true
 *
 * Destroys a resource. This method will destroy the underlying SysV semaphore.
 * If there is any code in other threads or processes blocking or using the resource
 * they will likely raise.
 *
 * Use this method very carefully.
 */
// EXPORTED
VALUE
semian_resource_destroy(VALUE self)
{
  semian_resource_t *res = NULL;

  TypedData_Get_Struct(self, semian_resource_t, &semian_resource_type, res);
  if (semctl(res->sem_id, 0, IPC_RMID) == -1) {
    raise_semian_syscall_error("semctl()", errno);
  }

  return Qtrue;
}

// EXPORTED
VALUE
semian_resource_count(VALUE self)
{
  int ret;
  semian_resource_t *res = NULL;

  TypedData_Get_Struct(self, semian_resource_t, &semian_resource_type, res);
  ret = semctl(res->sem_id, 0, GETVAL);
  if (ret == -1) {
    raise_semian_syscall_error("semctl()", errno);
  }

  return LONG2FIX(ret);
}

// EXPORTED
VALUE
semian_resource_id(VALUE self)
{
  semian_resource_t *res = NULL;
  TypedData_Get_Struct(self, semian_resource_t, &semian_resource_type, res);
  return LONG2FIX(res->sem_id);
}


// FIXME refactor
// EXPORTED
VALUE
semian_resource_initialize(VALUE self, VALUE id, VALUE tickets, VALUE quota, VALUE permissions, VALUE default_timeout)
{
  key_t key;
  int created = 0;
  semian_resource_t *res = NULL;
  const char *id_str = NULL;
  double c_quota = -1.0f;
  int c_tickets = -1;


  if ((TYPE(tickets) == T_NIL && TYPE(quota) == T_NIL) ||(TYPE(tickets) != T_NIL && TYPE(quota) != T_NIL)){
    rb_raise(rb_eArgError, "Must pass exactly one of ticket or quota");
  }
  else if (TYPE(quota) == T_NIL) {
    // If a quota has been specified, ignore the ticket count
    if (TYPE(tickets) == T_FLOAT) {
      rb_warn("semian ticket value %f is a float, converting to fixnum", RFLOAT_VALUE(tickets));
      tickets = INT2FIX((int) RFLOAT_VALUE(tickets));
    }
    Check_Type(tickets, T_FIXNUM);

    if (FIX2LONG(tickets) < 0 || FIX2LONG(tickets) > system_max_semaphore_count) {
      rb_raise(rb_eArgError, "ticket count must be a non-negative value and less than %d", system_max_semaphore_count);
    }
    c_tickets = FIX2LONG(tickets);
  }
  else if (TYPE(tickets) == T_NIL) {
    if (TYPE(quota) != T_FIXNUM && TYPE(quota) != T_FLOAT) {
      rb_raise(rb_eTypeError, "expected decimal type for quota");
    }
    if (NUM2DBL(quota) < 0 || NUM2DBL(quota) > 1) {
      rb_raise(rb_eArgError, "quota must be a decimal between 0 and 1");
    }
    c_quota = NUM2DBL(quota);
  }
  if (TYPE(id) != T_SYMBOL && TYPE(id) != T_STRING) {
    rb_raise(rb_eTypeError, "id must be a symbol or string");
  }
  Check_Type(permissions, T_FIXNUM);
  if (TYPE(default_timeout) != T_FIXNUM && TYPE(default_timeout) != T_FLOAT) {
    rb_raise(rb_eTypeError, "expected numeric type for default_timeout");
  }
  if (NUM2DBL(default_timeout) < 0) {
    rb_raise(rb_eArgError, "default timeout must be non-negative value");
  }
  if (TYPE(id) == T_SYMBOL) {
    id_str = rb_id2name(rb_to_id(id));
  } else if (TYPE(id) == T_STRING) {
    id_str = RSTRING_PTR(id);
  }

  TypedData_Get_Struct(self, semian_resource_t, &semian_resource_type, res);
  ms_to_timespec(NUM2DBL(default_timeout) * 1000, &res->timeout);
  res->name = strdup(id_str);
  res->quota = c_quota;

  key = generate_sem_set_key(id_str);
  res->sem_id = c_tickets == 0 ? get_semaphore(key) : create_semaphore(key, permissions, &created);

  if (res->sem_id == -1) {
    raise_semian_syscall_error("semget()", errno);
  }

  configure_tickets(res->sem_id, c_tickets, c_quota, created);

  set_semaphore_permissions(res->sem_id, FIX2LONG(permissions));

  return self;
}
