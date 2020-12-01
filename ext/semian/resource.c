#include "resource.h"

static VALUE
cleanup_semian_resource_acquire(VALUE self);

static void
check_tickets_xor_quota_arg(VALUE tickets, VALUE quota);

static double
check_quota_arg(VALUE quota);

static int
check_tickets_arg(VALUE tickets);

static int
check_is_global_arg(VALUE is_global);

static long
check_permissions_arg(VALUE permissions);

static const
char *check_id_arg(VALUE id);

static double
check_default_timeout_arg(VALUE default_timeout);

static void
ms_to_timespec(long ms, struct timespec *ts);

static const rb_data_type_t
semian_resource_type;

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
  acquire_semaphore_without_gvl(&res);
  if (res.error != 0) {
    if (res.error == EAGAIN) {
      rb_raise(eTimeout, "timed out waiting for resource '%s'", res.name);
    } else {
      raise_semian_syscall_error("semop()", res.error);
    }
  }

  VALUE wait_time = Qnil;
  if (res.wait_time >= 0) {
    wait_time = LONG2NUM(res.wait_time);
  }

  return rb_ensure(rb_yield, wait_time, cleanup_semian_resource_acquire, self);
}

VALUE
semian_resource_destroy(VALUE self)
{
  struct timespec ts = { 0 };
  ts.tv_sec = INTERNAL_TIMEOUT;

  semian_resource_t *res = NULL;

  TypedData_Get_Struct(self, semian_resource_t, &semian_resource_type, res);

  // Prevent a race to deletion
  if (perform_semop(res->sem_id, SI_SEM_LOCK, -1, 0, &ts) == -1) {
    if (errno == EINVAL || errno == EIDRM) {
      return Qtrue;
    }
  }

  if (semctl(res->sem_id, SI_NUM_SEMAPHORES, IPC_RMID) == -1) {
    raise_semian_syscall_error("semctl()", errno);
  }

  return Qtrue;
}

VALUE
semian_resource_reset_workers(VALUE self)
{
  int ret;
  semian_resource_t *res = NULL;

  TypedData_Get_Struct(self, semian_resource_t, &semian_resource_type, res);

  sem_meta_lock(res->sem_id);
  // This SETVAL will purge the SEM_UNDO table
  ret = semctl(res->sem_id, SI_SEM_REGISTERED_WORKERS, SETVAL, 0);
  sem_meta_unlock(res->sem_id);

  if (ret == -1) {
    raise_semian_syscall_error("semctl()", errno);
  }

  return Qtrue;
}

VALUE
semian_resource_unregister_worker(VALUE self)
{
  int ret;
  semian_resource_t *res = NULL;

  TypedData_Get_Struct(self, semian_resource_t, &semian_resource_type, res);

  sem_meta_lock(res->sem_id);
  ret = perform_semop(res->sem_id, SI_SEM_REGISTERED_WORKERS, -1, IPC_NOWAIT | SEM_UNDO, NULL);
  sem_meta_unlock(res->sem_id);

  if ( ret == -1) {
    // Allow EAGAIN with IPC_NOWAIT, as this signals that all workers were unregistered
    // Otherwise, we might block forever or throw an unintended timeout
    if (errno != EAGAIN) {
      rb_raise(eInternal, "error decreasing registered workers, errno: %d (%s)", errno, strerror(errno));
    }
  }

  return Qtrue;
}

VALUE
semian_resource_count(VALUE self)
{
  int ret;
  semian_resource_t *res = NULL;

  TypedData_Get_Struct(self, semian_resource_t, &semian_resource_type, res);
  ret = semctl(res->sem_id, SI_SEM_TICKETS, GETVAL);
  if (ret == -1) {
    raise_semian_syscall_error("semctl()", errno);
  }

  return LONG2FIX(ret);
}

VALUE
semian_resource_tickets(VALUE self)
{
  int ret;
  semian_resource_t *res = NULL;

  TypedData_Get_Struct(self, semian_resource_t, &semian_resource_type, res);
  ret = semctl(res->sem_id, SI_SEM_CONFIGURED_TICKETS, GETVAL);
  if (ret == -1) {
    raise_semian_syscall_error("semctl()", errno);
  }

  return LONG2FIX(ret);
}

VALUE
semian_resource_workers(VALUE self)
{
  int ret;
  semian_resource_t *res = NULL;

  TypedData_Get_Struct(self, semian_resource_t, &semian_resource_type, res);
  ret = semctl(res->sem_id, SI_SEM_REGISTERED_WORKERS, GETVAL);
  if (ret == -1) {
    raise_semian_syscall_error("semctl()", errno);
  }

  return LONG2FIX(ret);
}

VALUE
semian_resource_id(VALUE self)
{
  semian_resource_t *res = NULL;
  TypedData_Get_Struct(self, semian_resource_t, &semian_resource_type, res);
  return LONG2FIX(res->sem_id);
}

VALUE
semian_resource_key(VALUE self)
{
  semian_resource_t *res = NULL;
  TypedData_Get_Struct(self, semian_resource_t, &semian_resource_type, res);
  return rb_str_new_cstr(res->strkey);
}

VALUE
semian_resource_initialize(VALUE self, VALUE id, VALUE tickets, VALUE quota, VALUE permissions, VALUE default_timeout, VALUE is_global)
{
  long c_permissions;
  double c_timeout;
  double c_quota;
  int c_tickets;
  int c_is_global;
  semian_resource_t *res = NULL;
  const char *c_id_str = NULL;

  // Check and cast arguments
  check_tickets_xor_quota_arg(tickets, quota);
  c_quota = check_quota_arg(quota);
  c_tickets = check_tickets_arg(tickets);
  c_is_global = check_is_global_arg(is_global);
  c_permissions = check_permissions_arg(permissions);
  c_id_str = check_id_arg(id);
  c_timeout = check_default_timeout_arg(default_timeout);

  // Build semian resource structure
  TypedData_Get_Struct(self, semian_resource_t, &semian_resource_type, res);

  // Populate struct fields
  ms_to_timespec(c_timeout * 1000, &res->timeout);
  res->name = strdup(c_id_str);
  res->quota = c_quota;
  res->wait_time = -1;

  // Initialize the semaphore set
  initialize_semaphore_set(res, c_id_str, c_permissions, c_tickets, c_quota, c_is_global);

  return self;
}

VALUE
semian_resource_alloc(VALUE klass)
{
  semian_resource_t *res;
  VALUE obj = TypedData_Make_Struct(klass, semian_resource_t, &semian_resource_type, res);
  return obj;
}

VALUE
semian_resource_in_use(VALUE self)
{
  return Qtrue;
}

static VALUE
cleanup_semian_resource_acquire(VALUE self)
{
  semian_resource_t *res = NULL;
  TypedData_Get_Struct(self, semian_resource_t, &semian_resource_type, res);
  if (perform_semop(res->sem_id, SI_SEM_TICKETS, 1, SEM_UNDO, NULL) == -1) {
    res->error = errno;
  }
  return Qnil;
}

static long
check_permissions_arg(VALUE permissions)
{
  Check_Type(permissions, T_FIXNUM);
  return FIX2LONG(permissions);
}

static void
check_tickets_xor_quota_arg(VALUE tickets, VALUE quota)
{
  if ((TYPE(tickets) == T_NIL && TYPE(quota) == T_NIL) ||(TYPE(tickets) != T_NIL && TYPE(quota) != T_NIL)){
    rb_raise(rb_eArgError, "Must pass exactly one of ticket or quota");
  }
}

static double
check_quota_arg(VALUE quota)
{
  double c_quota;

  if (TYPE(quota) != T_NIL) {
    if (TYPE(quota) != T_FIXNUM && TYPE(quota) != T_FLOAT) {
      rb_raise(rb_eTypeError, "expected decimal type for quota");
    }
    if (NUM2DBL(quota) <= 0 || NUM2DBL(quota) > 1) {
      rb_raise(rb_eArgError, "quota must be a decimal between 0 and 1");
    }
    c_quota = NUM2DBL(quota);
  } else {
    c_quota = -1.0f;
  }
  return c_quota;
}

static int
check_tickets_arg(VALUE tickets)
{
  int c_tickets;

  if (TYPE(tickets) != T_NIL) {
    if (TYPE(tickets) == T_FLOAT) {
      rb_warn("semian ticket value %f is a float, converting to fixnum", RFLOAT_VALUE(tickets));
      tickets = INT2FIX((int) RFLOAT_VALUE(tickets));
    }
    Check_Type(tickets, T_FIXNUM);

    if (FIX2LONG(tickets) < 0 || FIX2LONG(tickets) > system_max_semaphore_count) {
      rb_raise(rb_eArgError, "ticket count must be a non-negative value and less than %d", system_max_semaphore_count);
    }
    c_tickets = FIX2LONG(tickets);
  } else {
    c_tickets = -1;
  }

  return c_tickets;
}

static int
check_is_global_arg(VALUE is_global)
{
  return RTEST(is_global);
}

static const char*
check_id_arg(VALUE id)
{
  const char *c_id_str = NULL;

  if (TYPE(id) != T_SYMBOL && TYPE(id) != T_STRING) {
    rb_raise(rb_eTypeError, "id must be a symbol or string");
  }
  if (TYPE(id) == T_SYMBOL) {
    c_id_str = rb_id2name(rb_to_id(id));
  } else if (TYPE(id) == T_STRING) {
    c_id_str = RSTRING_PTR(id);
  }

  return c_id_str;
}

static double
check_default_timeout_arg(VALUE default_timeout)
{
  if (TYPE(default_timeout) != T_FIXNUM && TYPE(default_timeout) != T_FLOAT) {
    rb_raise(rb_eTypeError, "expected numeric type for default_timeout");
  }

  if (NUM2DBL(default_timeout) < 0) {
    rb_raise(rb_eArgError, "default timeout must be non-negative value");
  }
  return NUM2DBL(default_timeout);
}

static void
ms_to_timespec(long ms, struct timespec *ts)
{
  ts->tv_sec = ms / 1000;
  ts->tv_nsec = (ms % 1000) * 1000000;
}

static inline void
semian_resource_mark(void *ptr)
{
  /* noop */
}

static inline void
semian_resource_free(void *ptr)
{
  semian_resource_t *res = (semian_resource_t *) ptr;
  if (res->name) {
    free(res->name);
    res->name = NULL;
  }
  xfree(res);
}

static inline size_t
semian_resource_memsize(const void *ptr)
{
  return sizeof(semian_resource_t);
}

static const rb_data_type_t
semian_resource_type = {
  "semian_resource",
  {
    semian_resource_mark,
    semian_resource_free,
    semian_resource_memsize
  },
  NULL, NULL, RUBY_TYPED_FREE_IMMEDIATELY
};
