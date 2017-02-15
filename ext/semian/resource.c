#include "resource.h"

static VALUE
cleanup_semian_resource_acquire(VALUE self);

static int
check_tickets_arg(VALUE tickets);

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
  WITHOUT_GVL(acquire_semaphore_without_gvl, &res, RUBY_UBF_IO, NULL); // FIXME - replace with wrapped version
  if (res.error != 0) {
    if (res.error == EAGAIN) {
      rb_raise(eTimeout, "timed out waiting for resource '%s'", res.name);
    } else {
      raise_semian_syscall_error("semop()", res.error);
    }
  }

  return rb_ensure(rb_yield, self, cleanup_semian_resource_acquire, self);
}

VALUE
semian_resource_destroy(VALUE self)
{
  semian_resource_t *res = NULL;

  TypedData_Get_Struct(self, semian_resource_t, &semian_resource_type, res);
  if (semctl(res->sem_id, SI_NUM_SEMAPHORES, IPC_RMID) == -1) {
    raise_semian_syscall_error("semctl()", errno);
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
semian_resource_id(VALUE self)
{
  semian_resource_t *res = NULL;
  TypedData_Get_Struct(self, semian_resource_t, &semian_resource_type, res);
  return LONG2FIX(res->sem_id);
}

VALUE
semian_resource_initialize(VALUE self, VALUE id, VALUE tickets, VALUE permissions, VALUE default_timeout)
{
  key_t key;
  int c_permissions;
  double c_timeout;
  int c_tickets;
  int created = 0;
  semian_resource_t *res = NULL;
  const char *c_id_str = NULL;

  // Check and cast arguments
  c_tickets = check_tickets_arg(tickets);
  c_permissions = check_permissions_arg(permissions);
  c_id_str = check_id_arg(id);
  c_timeout = check_default_timeout_arg(default_timeout);

  // Build semian resource structure
  TypedData_Get_Struct(self, semian_resource_t, &semian_resource_type, res);

  // Populate struct fields
  ms_to_timespec(c_timeout * 1000, &res->timeout);
  res->name = strdup(c_id_str);

  // Get or create semaphore set
  //  note that tickets = 0 will be used to acquire a semaphore set after it's been created elswhere
  key = generate_key(c_id_str);
  res->sem_id = c_tickets == 0 ? get_semaphore(key) : create_semaphore(key, c_permissions, &created);
  if (res->sem_id == -1) {
    raise_semian_syscall_error("semget()", errno);
  }

  set_semaphore_permissions(res->sem_id, c_permissions);

  // Configure semaphore ticket counts
  configure_tickets(res->sem_id, c_tickets, created);

  return self;
}

VALUE
semian_resource_alloc(VALUE klass)
{
  semian_resource_t *res;
  VALUE obj = TypedData_Make_Struct(klass, semian_resource_t, &semian_resource_type, res);
  return obj;
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
