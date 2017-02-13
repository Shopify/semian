#include <semian.h>

#if defined(HAVE_RB_THREAD_CALL_WITHOUT_GVL) && defined(HAVE_RUBY_THREAD_H)
// 2.0
#include <ruby/thread.h>
#define WITHOUT_GVL(fn,a,ubf,b) rb_thread_call_without_gvl((fn),(a),(ubf),(b))
#elif defined(HAVE_RB_THREAD_BLOCKING_REGION)
 // 1.9
typedef VALUE (*my_blocking_fn_t)(void*);
#define WITHOUT_GVL(fn,a,ubf,b) rb_thread_blocking_region((my_blocking_fn_t)(fn),(a),(ubf),(b))
#endif

static ID id_timeout;
static VALUE eSyscall, eTimeout, eInternal;
static int system_max_semaphore_count;

static key_t
generate_key(const char *name)
{
  union {
    unsigned char str[SHA_DIGEST_LENGTH];
    key_t key;
  } digest;
  SHA1((const unsigned char *) name, strlen(name), digest.str);
  /* TODO: compile-time assertion that sizeof(key_t) > SHA_DIGEST_LENGTH */
  return digest.key;
}

static void
ms_to_timespec(long ms, struct timespec *ts)
{
  ts->tv_sec = ms / 1000;
  ts->tv_nsec = (ms % 1000) * 1000000;
}

static void
raise_semian_syscall_error(const char *syscall, int error_num)
{
  rb_raise(eSyscall, "%s failed, errno: %d (%s)", syscall, error_num, strerror(error_num));
}

static void
semian_resource_mark(void *ptr)
{
  /* noop */
}

static void
semian_resource_free(void *ptr)
{
  semian_resource_t *res = (semian_resource_t *) ptr;
  if (res->name) {
    free(res->name);
    res->name = NULL;
  }
  xfree(res);
}

static size_t
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

static VALUE
semian_resource_alloc(VALUE klass)
{
  semian_resource_t *res;
  VALUE obj = TypedData_Make_Struct(klass, semian_resource_t, &semian_resource_type, res);
  return obj;
}

static void
set_semaphore_permissions(int sem_id, int permissions)
{
  union semun sem_opts;
  struct semid_ds stat_buf;

  sem_opts.buf = &stat_buf;
  semctl(sem_id, 0, IPC_STAT, sem_opts);
  if ((stat_buf.sem_perm.mode & 0xfff) != permissions) {
    stat_buf.sem_perm.mode &= ~0xfff;
    stat_buf.sem_perm.mode |= permissions;
    semctl(sem_id, 0, IPC_SET, sem_opts);
  }
}

static const int kInternalTimeout = 5; /* seconds */

static int
get_max_tickets(int sem_id)
{
  int ret = semctl(sem_id, SI_SEM_CONFIGURED_TICKETS, GETVAL);
  if (ret == -1) {
    rb_raise(eInternal, "error getting max ticket count, errno: %d (%s)", errno, strerror(errno));
  }
  return ret;
}

static int
perform_semop(int sem_id, short index, short op, short flags, struct timespec *ts)
{
  struct sembuf buf = { 0 };

  buf.sem_num = index;
  buf.sem_op  = op;
  buf.sem_flg = flags;

  if (ts) {
    return semtimedop(sem_id, &buf, 1, ts);
  } else {
    return semop(sem_id, &buf, 1);
  }
}

static VALUE
update_ticket_count(update_ticket_count_t *tc)
{
  short delta;
  struct timespec ts = { 0 };
  ts.tv_sec = kInternalTimeout;

  if (get_max_tickets(tc->sem_id) != tc->tickets) {
    delta = tc->tickets - get_max_tickets(tc->sem_id);

    if (perform_semop(tc->sem_id, SI_SEM_TICKETS, delta, 0, &ts) == -1) {
      rb_raise(eInternal, "error setting ticket count, errno: %d (%s)", errno, strerror(errno));
    }

    if (semctl(tc->sem_id, SI_SEM_CONFIGURED_TICKETS, SETVAL, tc->tickets) == -1) {
      rb_raise(eInternal, "error updating max ticket count, errno: %d (%s)", errno, strerror(errno));
    }
  }

  return Qnil;
}

static void
configure_tickets(int sem_id, int tickets, int should_initialize)
{
  struct timespec ts = { 0 };
  unsigned short init_vals[SI_NUM_SEMAPHORES];
  struct timeval start_time, cur_time;
  update_ticket_count_t tc;
  int state;

  if (should_initialize) {
    init_vals[SI_SEM_TICKETS] = init_vals[SI_SEM_CONFIGURED_TICKETS] = tickets;
    init_vals[SI_SEM_LOCK] = 1;
    if (semctl(sem_id, 0, SETALL, init_vals) == -1) {
      raise_semian_syscall_error("semctl()", errno);
    }
  } else if (tickets > 0) {
    /* it's possible that we haven't actually initialized the
       semaphore structure yet - wait a bit in that case */
    if (get_max_tickets(sem_id) == 0) {
      gettimeofday(&start_time, NULL);
      while (get_max_tickets(sem_id) == 0) {
        usleep(10000); /* 10ms */
        gettimeofday(&cur_time, NULL);
        if ((cur_time.tv_sec - start_time.tv_sec) > kInternalTimeout) {
          rb_raise(eInternal, "timeout waiting for semaphore initialization");
        }
      }
    }

    /*
       If the current max ticket count is not the same as the requested ticket
       count, we need to resize the count. We do this by adding the delta of
       (tickets - current_max_tickets) to the semaphore value.
    */
    if (get_max_tickets(sem_id) != tickets) {
      ts.tv_sec = kInternalTimeout;

      if (perform_semop(sem_id, SI_SEM_LOCK, -1, SEM_UNDO, &ts) == -1) {
        raise_semian_syscall_error("error acquiring internal semaphore lock, semtimedop()", errno);
      }

      tc.sem_id = sem_id;
      tc.tickets = tickets;
      rb_protect((VALUE (*)(VALUE)) update_ticket_count, (VALUE) &tc, &state);

      if (perform_semop(sem_id, SI_SEM_LOCK, 1, SEM_UNDO, NULL) == -1) {
        raise_semian_syscall_error("error releasing internal semaphore lock, semop()", errno);
      }

      if (state) {
        rb_jump_tag(state);
      }
    }
  }
}

static int
create_semaphore(int key, int permissions, int *created)
{
  int semid = 0;
  int flags = 0;

  *created = 0;
  flags = IPC_EXCL | IPC_CREAT | FIX2LONG(permissions);

  semid = semget(key, SI_NUM_SEMAPHORES, flags);
  if (semid >= 0) {
    *created = 1;
  } else if (semid == -1 && errno == EEXIST) {
    flags &= ~IPC_EXCL;
    semid = semget(key, SI_NUM_SEMAPHORES, flags);
  }
  return semid;
}

static int
get_semaphore(int key)
{
  return semget(key, SI_NUM_SEMAPHORES, 0);
}

/*
 * call-seq:
 *    Semian::Resource.new(id, tickets, permissions, default_timeout) -> resource
 *
 * Creates a new Resource. Do not create resources directly. Use Semian.register.
 */
static VALUE
semian_resource_initialize(VALUE self, VALUE id, VALUE tickets, VALUE permissions, VALUE default_timeout)
{
  key_t key;
  int created = 0;
  semian_resource_t *res = NULL;
  const char *id_str = NULL;

  if (TYPE(id) != T_SYMBOL && TYPE(id) != T_STRING) {
    rb_raise(rb_eTypeError, "id must be a symbol or string");
  }
  if (TYPE(tickets) == T_FLOAT) {
    rb_warn("semian ticket value %f is a float, converting to fixnum", RFLOAT_VALUE(tickets));
    tickets = INT2FIX((int) RFLOAT_VALUE(tickets));
  }
  Check_Type(tickets, T_FIXNUM);
  Check_Type(permissions, T_FIXNUM);
  if (TYPE(default_timeout) != T_FIXNUM && TYPE(default_timeout) != T_FLOAT) {
    rb_raise(rb_eTypeError, "expected numeric type for default_timeout");
  }
  if (FIX2LONG(tickets) < 0 || FIX2LONG(tickets) > system_max_semaphore_count) {
    rb_raise(rb_eArgError, "ticket count must be a non-negative value and less than %d", system_max_semaphore_count);
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
  key = generate_key(id_str);
  ms_to_timespec(NUM2DBL(default_timeout) * 1000, &res->timeout);
  res->name = strdup(id_str);

  res->sem_id = FIX2LONG(tickets) == 0 ? get_semaphore(key) : create_semaphore(key, permissions, &created);
  if (res->sem_id == -1) {
    raise_semian_syscall_error("semget()", errno);
  }

  configure_tickets(res->sem_id, FIX2LONG(tickets), created);

  set_semaphore_permissions(res->sem_id, FIX2LONG(permissions));

  return self;
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

static void *
acquire_semaphore_without_gvl(void *p)
{
  semian_resource_t *res = (semian_resource_t *) p;
  res->error = 0;
  if (perform_semop(res->sem_id, SI_SEM_TICKETS, -1, SEM_UNDO, &res->timeout) == -1) {
    res->error = errno;
  }
  return NULL;
}

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
static VALUE
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
static VALUE
semian_resource_destroy(VALUE self)
{
  semian_resource_t *res = NULL;

  TypedData_Get_Struct(self, semian_resource_t, &semian_resource_type, res);
  if (semctl(res->sem_id, 0, IPC_RMID) == -1) {
    raise_semian_syscall_error("semctl()", errno);
  }

  return Qtrue;
}

/*
 * call-seq:
 *    resource.count -> count
 *
 * Returns the current ticket count for a resource.
 */
static VALUE
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

/*
 * call-seq:
 *    resource.semid -> id
 *
 * Returns the SysV semaphore id of a resource.
 */
static VALUE
semian_resource_id(VALUE self)
{
  semian_resource_t *res = NULL;
  TypedData_Get_Struct(self, semian_resource_t, &semian_resource_type, res);
  return LONG2FIX(res->sem_id);
}

void Init_semian()
{
  VALUE cSemian, cResource;
  struct seminfo info_buf;

  cSemian = rb_const_get(rb_cObject, rb_intern("Semian"));

  /*
   * Document-class: Semian::Resource
   *
   *  Resource is the fundamental class of Semian. It is essentially a wrapper around a
   *  SystemV semaphore.
   *
   *  You should not create this class directly, it will be created indirectly via Semian.register.
   */
  cResource = rb_const_get(cSemian, rb_intern("Resource"));

  /* Document-class: Semian::SyscallError
   *
   * Represents a Semian error that was caused by an underlying syscall failure.
   */
  eSyscall = rb_const_get(cSemian, rb_intern("SyscallError"));

  /* Document-class: Semian::TimeoutError
   *
   * Raised when a Semian operation timed out.
   */
  eTimeout = rb_const_get(cSemian, rb_intern("TimeoutError"));

  /* Document-class: Semian::InternalError
   *
   * An internal Semian error. These errors should be typically never be raised. If
   * they do, there's a high likelyhood that the underlying SysV semaphore set
   * has been corrupted.
   *
   * If this happens, a strong course of action would be to delete the semaphores
   * using the <code>ipcrm</code> command line tool. Semian will re-initialize
   * the semaphore in this case.
   */
  eInternal = rb_const_get(cSemian, rb_intern("InternalError"));

  rb_define_alloc_func(cResource, semian_resource_alloc);
  rb_define_method(cResource, "initialize_semaphore", semian_resource_initialize, 4);
  rb_define_method(cResource, "acquire", semian_resource_acquire, -1);
  rb_define_method(cResource, "count", semian_resource_count, 0);
  rb_define_method(cResource, "semid", semian_resource_id, 0);
  rb_define_method(cResource, "destroy", semian_resource_destroy, 0);

  id_timeout = rb_intern("timeout");

  if (semctl(0, 0, SEM_INFO, &info_buf) == -1) {
    rb_raise(eInternal, "unable to determine maximum semaphore count - semctl() returned %d: %s ", errno, strerror(errno));
  }
  system_max_semaphore_count = info_buf.semvmx;

  /* Maximum number of tickets available on this system. */
  rb_define_const(cSemian, "MAX_TICKETS", INT2FIX(system_max_semaphore_count));
}
