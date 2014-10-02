#include <sys/types.h>
#include <sys/ipc.h>
#include <sys/sem.h>
#include <errno.h>
#include <string.h>

#include <ruby.h>
#include <ruby/util.h>
#include <ruby/io.h>

#include <openssl/sha.h>

#include <stdio.h>

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
static VALUE eSyscall, eTimeout;

typedef struct {
  int sem_id;
  struct timespec timeout;
  int error;
  char *name;
} semian_resource_t;

static key_t
generate_key(const char *name)
{
  char digest[SHA_DIGEST_LENGTH];
  SHA1(name, strlen(name), digest);
  /* TODO: compile-time assertion that sizeof(key_t) > SHA_DIGEST_LENGTH */
  return *((key_t *) digest);
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

static VALUE
semian_resource_initialize(VALUE self, VALUE id, VALUE tickets, VALUE permissions, VALUE default_timeout)
{
  key_t key;
  int flags = 0;
  semian_resource_t *res = NULL;
  const char *id_str = NULL;

  if (TYPE(id) != T_SYMBOL && TYPE(id) != T_STRING) {
    rb_raise(rb_eTypeError, "id must be a symbol or string");
  }
  Check_Type(tickets, T_FIXNUM);
  Check_Type(permissions, T_FIXNUM);
  if (TYPE(default_timeout) != T_FIXNUM && TYPE(default_timeout) != T_FLOAT) {
    rb_raise(rb_eTypeError, "expected numeric type for default_timeout");
  }
  if (FIX2LONG(tickets) < 0) {
    rb_raise(rb_eArgError, "ticket count must be a non-negative value");
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

  if (FIX2LONG(tickets) != 0) {
    flags |= IPC_CREAT;
  }

  flags |= FIX2LONG(permissions);

  res->sem_id = semget(key, 1, flags);
  if (res->sem_id == -1) {
    raise_semian_syscall_error("semget()", errno);
  }

  if (FIX2LONG(tickets) != 0
      && semctl(res->sem_id, 0, SETVAL, FIX2LONG(tickets)) == -1) {
    raise_semian_syscall_error("semctl()", errno);
  }

  return self;
}

static VALUE
cleanup_semian_resource_acquire(VALUE self)
{
  semian_resource_t *res = NULL;
  TypedData_Get_Struct(self, semian_resource_t, &semian_resource_type, res);
  struct sembuf buf = { 0, 1, SEM_UNDO };
  if (semop(res->sem_id, &buf, 1) == -1) {
    res->error = errno;
  }
  return Qnil;
}

static void *
acquire_sempahore_without_gvl(void *p)
{
  semian_resource_t *res = (semian_resource_t *) p;
  struct sembuf buf = { 0, -1, SEM_UNDO };
  res->error = 0;
  if (semtimedop(res->sem_id, &buf, 1, &res->timeout) == -1) {
    res->error = errno;
  }
  return NULL;
}

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
  WITHOUT_GVL(acquire_sempahore_without_gvl, &res, RUBY_UBF_IO, NULL);
  if (res.error != 0) {
    if (res.error == EAGAIN) {
      rb_raise(eTimeout, "timed out waiting for resource '%s'", res.name);
    } else {
      raise_semian_syscall_error("semop()", res.error);
    }
  }

  return rb_ensure(rb_yield, self, cleanup_semian_resource_acquire, self);
}

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

void Init_semian()
{
  VALUE cSemian, cResource, eBaseError;

  cSemian = rb_define_class("Semian", rb_cObject);
  cResource = rb_define_class("Resource", cSemian);
  eBaseError = rb_define_class_under(cSemian, "BaseError", rb_eStandardError);
  eSyscall = rb_define_class_under(cSemian, "SyscallError", eBaseError);
  eTimeout = rb_define_class_under(cSemian, "TimeoutError", eBaseError);

  rb_define_alloc_func(cResource, semian_resource_alloc);
  rb_define_method(cResource, "initialize", semian_resource_initialize, 4);
  rb_define_method(cResource, "acquire", semian_resource_acquire, -1);
  rb_define_method(cResource, "count", semian_resource_count, 0);
  rb_define_method(cResource, "destroy", semian_resource_destroy, 0);

  id_timeout = rb_intern("timeout");
}
