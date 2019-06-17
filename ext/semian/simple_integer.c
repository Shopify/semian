#include "simple_integer.h"

#include "sysv_semaphores.h"
#include "sysv_shared_memory.h"
#include "types.h"
#include "util.h"

void
semian_simple_integer_dfree(void* ptr)
{
  semian_simple_integer_t* res = (semian_simple_integer_t*)ptr;
  free_shared_memory(res->shmem);
}

size_t
semian_simple_integer_dsize(const void* ptr)
{
  return sizeof(semian_simple_integer_t);
}

static const rb_data_type_t semian_simple_integer_type = {
  .wrap_struct_name = "semian_simple_integer",
  .function = {
    .dmark = NULL,
    .dfree = semian_simple_integer_dfree,
    .dsize = semian_simple_integer_dsize,
  },
  .data = NULL,
  .flags = RUBY_TYPED_FREE_IMMEDIATELY,
};

static void init_fn(void* ptr)
{
  semian_simple_integer_shared_t* res = (semian_simple_integer_shared_t*)ptr;
  res->val = 0;
}

void
Init_SimpleInteger()
{
  dprintf("Init_SimpleInteger\n");

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

VALUE
semian_simple_integer_alloc(VALUE klass)
{
  semian_simple_integer_t *res;
  VALUE obj = TypedData_Make_Struct(klass, semian_simple_integer_t, &semian_simple_integer_type, res);
  return obj;
}

VALUE
semian_simple_integer_initialize(VALUE self, VALUE name)
{
  semian_simple_integer_t *res;
  TypedData_Get_Struct(self, semian_simple_integer_t, &semian_simple_integer_type, res);
  res->key = generate_key(to_s(name));

  dprintf("Initializing simple integer '%s' (key: %lu)", to_s(name), res->key);
  res->sem_id = initialize_single_semaphore(res->key, SEM_DEFAULT_PERMISSIONS);
  res->shmem = get_or_create_shared_memory(res->key, &init_fn);

  return self;
}

VALUE
semian_simple_integer_increment(int argc, VALUE *argv, VALUE self)
{
  // This is definitely the worst API ever.
  // https://silverhammermba.github.io/emberb/c/#parsing-arguments
  VALUE val;
  semian_simple_integer_t *res;
  VALUE retval;

  rb_scan_args(argc, argv, "01", &val);

  TypedData_Get_Struct(self, semian_simple_integer_t, &semian_simple_integer_type, res);

  sem_meta_lock(res->sem_id);
  {
    if (NIL_P(val)) {
      res->shmem->val += 1;
    } else {
      res->shmem->val += RB_NUM2INT(val);
    }
    retval = RB_INT2NUM(res->shmem->val);
  }
  sem_meta_unlock(res->sem_id);

  return retval;
}

VALUE
semian_simple_integer_reset(VALUE self)
{
  semian_simple_integer_t *res;
  VALUE retval;

  TypedData_Get_Struct(self, semian_simple_integer_t, &semian_simple_integer_type, res);

  sem_meta_lock(res->sem_id);
  {
    res->shmem->val = 0;
    retval = RB_INT2NUM(res->shmem->val);
  }
  sem_meta_unlock(res->sem_id);

  return retval;
}

VALUE
semian_simple_integer_value_get(VALUE self)
{
  semian_simple_integer_t *res;
  VALUE retval;

  TypedData_Get_Struct(self, semian_simple_integer_t, &semian_simple_integer_type, res);

  sem_meta_lock(res->sem_id);
  {
    retval = RB_INT2NUM(res->shmem->val);
  }
  sem_meta_unlock(res->sem_id);

  return retval;
}

VALUE
semian_simple_integer_value_set(VALUE self, VALUE val)
{
  semian_simple_integer_t *res;
  VALUE retval;

  TypedData_Get_Struct(self, semian_simple_integer_t, &semian_simple_integer_type, res);

  sem_meta_lock(res->sem_id);
  {
    // TODO(michaelkipper): Check for respond_to?(:to_i) before calling.
    VALUE to_i = rb_funcall(val, rb_intern("to_i"), 0);
    res->shmem->val = RB_NUM2INT(to_i);
    retval = RB_INT2NUM(res->shmem->val);
  }
  sem_meta_unlock(res->sem_id);

  return retval;
}
