#include "simple_integer.h"

#include <errno.h>
#include <sys/ipc.h>
#include <sys/shm.h>
#include "types.h"
#include "util.h"
#include "sysv_semaphores.h"

static const rb_data_type_t semian_simple_integer_type;

static semian_simple_integer_shared_t* get_value(semian_simple_integer_t* res) {
  int shmid = shmget(res->key, sizeof(semian_simple_integer_shared_t), IPC_CREAT | SEM_DEFAULT_PERMISSIONS);
  if (shmid == -1) {
    rb_raise(rb_eArgError, "could not create shared memory (%s)", strerror(errno));
  }

  void *val = shmat(shmid, NULL, 0);
  if (val == (void*)-1) {
    rb_raise(rb_eArgError, "could not get shared memory (%s)", strerror(errno));
  }

  return (semian_simple_integer_shared_t*)val;
}

void Init_SimpleInteger()
{
  printf("[DEBUG] Init_SimpleInteger\n");

  VALUE cSemian = rb_const_get(rb_cObject, rb_intern("Semian"));
  VALUE cSimple = rb_const_get(cSemian, rb_intern("Simple"));
  VALUE cSimpleInteger = rb_const_get(cSimple, rb_intern("Integer"));

  rb_define_alloc_func(cSimpleInteger, semian_simple_integer_alloc);
  rb_define_method(cSimpleInteger, "initialize_simple_integer", semian_simple_integer_initialize, 1);
  rb_define_method(cSimpleInteger, "increment", semian_simple_integer_increment, -1);
  rb_define_method(cSimpleInteger, "reset", semian_simple_integer_reset, 0);
  rb_define_method(cSimpleInteger, "value", semian_simple_integer_value_get, 0);
  rb_define_method(cSimpleInteger, "value=", semian_simple_integer_value_set, 1);
}

VALUE semian_simple_integer_alloc(VALUE klass)
{
  semian_simple_integer_t *res;
  VALUE obj = TypedData_Make_Struct(klass, semian_simple_integer_t, &semian_simple_integer_type, res);
  return obj;
}


VALUE semian_simple_integer_initialize(VALUE self, VALUE name)
{
  semian_simple_integer_t *res;
  TypedData_Get_Struct(self, semian_simple_integer_t, &semian_simple_integer_type, res);
  res->key = generate_key(to_s(name));

  semian_simple_integer_shared_t* data = get_value(res);
  data->val = 0;

  res->sem_id = initialize_single_semaphore(res->key, SEM_DEFAULT_PERMISSIONS);

  return self;
}

VALUE semian_simple_integer_increment(int argc, VALUE *argv, VALUE self) {
  // This is definitely the worst API ever.
  // https://silverhammermba.github.io/emberb/c/#parsing-arguments
  VALUE val;
  semian_simple_integer_t *res;
  VALUE rb_val;

  rb_scan_args(argc, argv, "01", &val);

  TypedData_Get_Struct(self, semian_simple_integer_t, &semian_simple_integer_type, res);

  sem_meta_lock(res->sem_id);
  {
    semian_simple_integer_shared_t *data = get_value(res);

    if (NIL_P(val)) {
      data->val += 1;
    } else {
      data->val += RB_NUM2INT(val);
    }
    rb_val = RB_INT2NUM(data->val);
  }
  sem_meta_unlock(res->sem_id);

  return rb_val;
}

VALUE semian_simple_integer_reset(VALUE self) {
  semian_simple_integer_t *res;
  VALUE rb_val;

  TypedData_Get_Struct(self, semian_simple_integer_t, &semian_simple_integer_type, res);

  sem_meta_lock(res->sem_id);
  {
    semian_simple_integer_shared_t *data = get_value(res);
    data->val = 0;
    rb_val = RB_INT2NUM(data->val);
  }
  sem_meta_unlock(res->sem_id);

  return rb_val;
}

VALUE semian_simple_integer_value_get(VALUE self) {
  semian_simple_integer_t *res;
  VALUE rb_val;

  TypedData_Get_Struct(self, semian_simple_integer_t, &semian_simple_integer_type, res);

  sem_meta_lock(res->sem_id);
  {
    semian_simple_integer_shared_t *data = get_value(res);
    rb_val = RB_INT2NUM(data->val);
  }
  sem_meta_unlock(res->sem_id);

  return rb_val;
}

VALUE semian_simple_integer_value_set(VALUE self, VALUE val) {
  semian_simple_integer_t *res;
  VALUE rb_val;

  TypedData_Get_Struct(self, semian_simple_integer_t, &semian_simple_integer_type, res);

  sem_meta_lock(res->sem_id);
  {
    semian_simple_integer_shared_t *data = get_value(res);

    // TODO(michaelkipper): Check for respond_to?(:to_i) before calling.
    VALUE to_i = rb_funcall(val, rb_intern("to_i"), 0);
    data->val = RB_NUM2INT(to_i);
    rb_val = RB_INT2NUM(data->val);
  }
  sem_meta_unlock(res->sem_id);

  return rb_val;
}
