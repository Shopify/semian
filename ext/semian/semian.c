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
static VALUE eTimeout;

typedef struct {
  int sem_id;
  struct timespec timeout;
  int error;
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
semian_resource_mark(void *ptr)
{
  /* noop */
}

static void
semian_resource_free(void *ptr)
{
  semian_resource_t *res = (semian_resource_t *) ptr;
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
semian_resource_initialize(VALUE self, VALUE id, VALUE tickets, VALUE default_timeout)
{
  key_t key;
  semian_resource_t *res = NULL;
  const char *id_str = NULL;

  Check_Type(id, T_SYMBOL);
  Check_Type(tickets, T_FIXNUM);
  if (TYPE(default_timeout) != T_FIXNUM && TYPE(default_timeout) != T_FLOAT) {
    rb_raise(rb_eTypeError, "expected numeric type for default_timeout");
  }
  if (FIX2LONG(tickets) < 0) {
    rb_raise(rb_eArgError, "ticket count must be a positive value greater than or equal to zero");
  }
  if (NUM2DBL(default_timeout) < 0) {
    rb_raise(rb_eArgError, "default timeout must be greater than or equal to zero");
  }

  id_str = rb_id2name(rb_to_id(id));
  TypedData_Get_Struct(self, semian_resource_t, &semian_resource_type, res);
  key = generate_key(id_str);
  ms_to_timespec(NUM2DBL(default_timeout) * 1000, &res->timeout);

  res->sem_id = semget(key, 1, IPC_CREAT | S_IRWXU);
  if (res->sem_id == -1) {
    rb_raise(rb_eRuntimeError, "semget() failed: %s (%d)", strerror(errno), errno);
  }

  if (FIX2LONG(tickets) != 0
      && semctl(res->sem_id, 0, SETVAL, FIX2LONG(tickets)) == -1) {
    rb_raise(rb_eRuntimeError, "semctl() failed: %s (%d)", strerror(errno), errno);
  }

  return Qnil;
}

static VALUE
do_semian_resource_acquire(VALUE self)
{
  return rb_yield(Qnil);
}

static VALUE
cleanup_semian_resource_acquire(VALUE self)
{
  semian_resource_t *res = NULL;
  TypedData_Get_Struct(self, semian_resource_t, &semian_resource_type, res);
  struct sembuf buf = { 0, 1, 0 };
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
      rb_raise(eTimeout, "timed out");
    } else {
      rb_raise(rb_eRuntimeError, "semop() error: %s (%d)", strerror(res.error), res.error);
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
    rb_raise(rb_eRuntimeError, "semctl() error: %s (%d)", strerror(errno), errno);
  }

  return Qnil;
}

static VALUE
semian_resource_count(VALUE self)
{
  int ret;
  semian_resource_t *res = NULL;

  TypedData_Get_Struct(self, semian_resource_t, &semian_resource_type, res);
  ret = semctl(res->sem_id, 0, GETVAL);
  if (ret == -1) {
    rb_raise(rb_eRuntimeError, "semctl() error: %s (%d)", strerror(errno), errno);
  }

  return LONG2FIX(ret);
}

void Init_semian()
{
  VALUE cSemian, cResource;

  cSemian = rb_define_class("Semian", rb_cObject);
  cResource = rb_define_class("Resource", cSemian);
  eTimeout = rb_define_class_under(cSemian, "Timeout", rb_eStandardError);

  rb_define_alloc_func(cResource, semian_resource_alloc);
  rb_define_method(cResource, "initialize", semian_resource_initialize, 3);
  rb_define_method(cResource, "acquire", semian_resource_acquire, -1);
  rb_define_method(cResource, "count", semian_resource_count, 0);
  rb_define_method(cResource, "destroy", semian_resource_destroy, 0);

  id_timeout = rb_intern("timeout");
}
