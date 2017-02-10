#include <sys/types.h>
#include <sys/ipc.h>
#include <sys/sem.h>
#include <sys/time.h>
#include <errno.h>
#include <string.h>

#include <ruby.h>
#include <ruby/util.h>
#include <ruby/io.h>

#include <openssl/sha.h>

#include <stdio.h>

union semun {
  int              val;    /* Value for SETVAL */
  struct semid_ds *buf;    /* Buffer for IPC_STAT, IPC_SET */
  unsigned short  *array;  /* Array for GETALL, SETALL */
  struct seminfo  *__buf;  /* Buffer for IPC_INFO
                             (Linux-specific) */
};

#if defined(HAVE_RB_THREAD_CALL_WITHOUT_GVL) && defined(HAVE_RUBY_THREAD_H)
// 2.0
#include <ruby/thread.h>
#define WITHOUT_GVL(fn,a,ubf,b) rb_thread_call_without_gvl((fn),(a),(ubf),(b))
#elif defined(HAVE_RB_THREAD_BLOCKING_REGION)
 // 1.9
typedef VALUE (*my_blocking_fn_t)(void*);
#define WITHOUT_GVL(fn,a,ubf,b) rb_thread_blocking_region((my_blocking_fn_t)(fn),(a),(ubf),(b))
#endif

#define INTERNAL_TIMEOUT 5 // seconds

// Here we define an enum value and string representation of each semaphore
// This allows us to key the sem value and string rep in sync easily
// utilizing pre-processor macros.
//   SI_SEM_TICKETS             semaphore for the tickets currently issued
//   SI_SEM_CONFIGURED_TICKETS  semaphore to track the desired number of tickets available for issue
//   SI_SEM_LOCK                metadata lock to act as a mutex, ensuring thread-safety for updating other semaphores
//   SI_SEM_REGISTERED_WORKERS  semaphore for the number of workers currently registered
//   SI_SEM_CONFIGURED_WORKERS  semaphore for the number of workers that our quota is using for configured tickets
//   SI_NUM_SEMAPHORES          always leave this as last entry for count to be accurate
#define FOREACH_SEMINDEX(SEMINDEX) \
        SEMINDEX(SI_SEM_TICKETS)   \
        SEMINDEX(SI_SEM_CONFIGURED_TICKETS)  \
        SEMINDEX(SI_SEM_LOCK)   \
        SEMINDEX(SI_SEM_REGISTERED_WORKERS)  \
        SEMINDEX(SI_SEM_CONFIGURED_WORKERS)  \
        SEMINDEX(SI_NUM_SEMAPHORES)  \

#define GENERATE_ENUM(ENUM) ENUM,
#define GENERATE_STRING(STRING) #STRING,

enum SEMINDEX_ENUM {
    FOREACH_SEMINDEX(GENERATE_ENUM)
};

static const char *SEMINDEX_STRING[] = {
    FOREACH_SEMINDEX(GENERATE_STRING)
};

static ID id_timeout;
static VALUE eSyscall, eTimeout, eInternal;
static int system_max_semaphore_count;

typedef struct {
  int sem_id;
  struct timespec timeout;
  double quota;
  int error;
  char *name;
} semian_resource_t;

static key_t
generate_key(const char *name)
{
  char semset_size_key[20];
  char *uniq_id_str;

  // It is necessary for the cardinatily of the semaphore set to be part of the key
  // or else sem_get will complain that we have requested an incorrect number of sems
  // for the desired key, and have changed the number of semaphores for a given key
  sprintf(semset_size_key, "_NUM_SEMS_%d", SI_NUM_SEMAPHORES);
  uniq_id_str = malloc(strlen(name)+strlen(semset_size_key)+1);
  strcpy(uniq_id_str, name);
  strcat(uniq_id_str, semset_size_key);

  union {
    unsigned char str[SHA_DIGEST_LENGTH];
    key_t key;
  } digest;
  SHA1((const unsigned char *) uniq_id_str, strlen(uniq_id_str), digest.str);
  free(uniq_id_str);
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

static int
get_sem_val(int sem_id, int sem_index)
{
  int ret = semctl(sem_id, sem_index, GETVAL);
  if (ret == -1) {
    rb_raise(eInternal, "error getting value of %s, errno: %d (%s)", SEMINDEX_STRING[sem_index], errno, strerror(errno));
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

typedef struct {
  int sem_id;
  int tickets;
} update_ticket_count_t;

static VALUE
update_ticket_count(update_ticket_count_t *tc)
{
  short delta;
  struct timespec ts = { 0 };
  ts.tv_sec = INTERNAL_TIMEOUT;

  if (get_sem_val(tc->sem_id, SI_SEM_CONFIGURED_TICKETS) != tc->tickets) {
    delta = tc->tickets - get_sem_val(tc->sem_id, SI_SEM_CONFIGURED_TICKETS);

    if (perform_semop(tc->sem_id, SI_SEM_TICKETS, delta, 0, &ts) == -1) {
      rb_raise(eInternal, "error setting ticket count, errno: %d (%s)", errno, strerror(errno));
    }

    if (semctl(tc->sem_id, SI_SEM_CONFIGURED_TICKETS, SETVAL, tc->tickets) == -1) {
      rb_raise(eInternal, "error updating configured ticket count, errno: %d (%s)", errno, strerror(errno));
    }
  }

  return Qnil;
}

static void
sem_meta_lock(int sem_id)
{
  struct timespec ts = { 0 };
  ts.tv_sec = INTERNAL_TIMEOUT;

  if (perform_semop(sem_id, SI_SEM_LOCK, -1, SEM_UNDO, &ts) == -1) {
    raise_semian_syscall_error("error acquiring internal semaphore lock, semtimedop()", errno);
  }
}

static void
sem_meta_unlock(int sem_id)
{
  if (perform_semop(sem_id, SI_SEM_LOCK, 1, SEM_UNDO, NULL) == -1) {
    raise_semian_syscall_error("error releasing internal semaphore lock, semop()", errno);
  }
}

static int
update_tickets_from_quota(int sem_id, double quota)
{
  int delta = 0;
  int tickets = 0;
  int state;
  update_ticket_count_t tc;
  struct timespec ts = { 0 };

  ts.tv_sec = INTERNAL_TIMEOUT;

  //printf("Updating based on quota %f\n", quota);
  // If the configured worker count doesn't match the registered worker count, adjust it.
  // and adjust the underlying tickets available to match.
  delta = get_sem_val(sem_id, SI_SEM_REGISTERED_WORKERS) - get_sem_val(sem_id, SI_SEM_CONFIGURED_WORKERS);
  if (delta != 0) {
    if (perform_semop(sem_id, SI_SEM_CONFIGURED_WORKERS, delta, 0, &ts) == -1) {
      rb_raise(eInternal, "error setting configured workers, errno: %d (%s)", errno, strerror(errno));
    }

    // Compute the ticket count
    tickets = (int) ceil(get_sem_val(sem_id, SI_SEM_CONFIGURED_WORKERS) * quota);
    //printf("Configured ticket count %d with quota %f and workers %d\n", tickets, quota, get_sem_val(sem_id, SI_SEM_CONFIGURED_WORKERS));
    tc.sem_id = sem_id;
    tc.tickets = tickets;
    rb_protect((VALUE (*)(VALUE)) update_ticket_count, (VALUE) &tc, &state);
  }

  return state;
}

static void
configure_tickets(int sem_id, int tickets, double quota, int should_initialize)
{
  struct timespec ts = { 0 };
  unsigned short init_vals[SI_NUM_SEMAPHORES];
  struct timeval start_time, cur_time;
  update_ticket_count_t tc;
  int state;

  if (should_initialize) {

    // desired tickets and configured tickets must be calculated based on quota if quota is provided
    // if a quoted is provided, should be initialzied to 0 instead of tickets

    // ticket was specified, not quota
    if (tickets > 0) {
      init_vals[SI_SEM_TICKETS] = init_vals[SI_SEM_CONFIGURED_TICKETS] = tickets;
      init_vals[SI_SEM_REGISTERED_WORKERS] = init_vals[SI_SEM_CONFIGURED_WORKERS] = 0;
    }
    // quota was specified, not tickets
    else if (quota > 0) {
      init_vals[SI_SEM_TICKETS] = init_vals[SI_SEM_CONFIGURED_TICKETS] = 0;
      init_vals[SI_SEM_REGISTERED_WORKERS] = init_vals[SI_SEM_CONFIGURED_WORKERS] = 0;
    }
    init_vals[SI_SEM_LOCK] = 1;
    if (semctl(sem_id, 0, SETALL, init_vals) == -1) {
      raise_semian_syscall_error("semctl()", errno);
    }
  } else if (tickets > 0) {
    /* it's possible that we haven't actually initialized the
       semaphore structure yet - wait a bit in that case */
    if (get_sem_val(sem_id, SI_SEM_CONFIGURED_TICKETS) == 0) {
      gettimeofday(&start_time, NULL);
      while (get_sem_val(sem_id, SI_SEM_CONFIGURED_TICKETS) == 0) {
        usleep(10000); /* 10ms */
        gettimeofday(&cur_time, NULL);
        if ((cur_time.tv_sec - start_time.tv_sec) > INTERNAL_TIMEOUT) {
          rb_raise(eInternal, "timeout waiting for semaphore initialization");
        }
      }
    }

    /*
       If the current configured ticket count is not the same as the requested ticket
       count, we need to resize the count. We do this by adding the delta of
       (tickets - current_configured_tickets) to the semaphore value.
    */
    if (get_sem_val(sem_id, SI_SEM_CONFIGURED_TICKETS) != tickets) {

      sem_meta_lock(sem_id);

      tc.sem_id = sem_id;
      tc.tickets = tickets;
      rb_protect((VALUE (*)(VALUE)) update_ticket_count, (VALUE) &tc, &state);

      sem_meta_unlock(sem_id);

      if (state) {
        rb_jump_tag(state);
      }
    }
  }
  if (quota > 0) {
    // TO DO - is a spinwait needed here?
    sem_meta_lock(sem_id);

    // Ensure that a worker for this process is registered
    if (perform_semop(sem_id, SI_SEM_REGISTERED_WORKERS, 1, 0, &ts) == -1) {
      rb_raise(eInternal, "error incrementing registered workers, errno: %d (%s)", errno, strerror(errno));
    }

    // Ensure that our max tickets matches the quota
    state = update_tickets_from_quota(sem_id, quota);
    sem_meta_unlock(sem_id);

    if (state) {
      rb_jump_tag(state);
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

  key = generate_key(id_str);
  res->sem_id = c_tickets == 0 ? get_semaphore(key) : create_semaphore(key, permissions, &created);

  if (res->sem_id == -1) {
    raise_semian_syscall_error("semget()", errno);
  }

  configure_tickets(res->sem_id, c_tickets, c_quota, created);

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
  rb_define_method(cResource, "initialize_semaphore", semian_resource_initialize, 5);
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
