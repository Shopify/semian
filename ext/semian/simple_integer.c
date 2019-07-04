#include "simple_integer.h"

#include "sysv_semaphores.h"
#include "types.h"
#include "util.h"

void
semian_simple_integer_dfree(void* ptr)
{
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

int check_increment_arg(VALUE val)
{
  VALUE retval;

  switch (rb_type(val)) {
  case T_NIL:
  case T_UNDEF:
    retval = 1; break;
  case T_FLOAT:
    rb_warn("incrementing SingleInteger by a floating point value, converting to fixnum");
    retval = (int)(RFLOAT_VALUE(val)); break;
  case T_FIXNUM:
  case T_BIGNUM:
    retval = RB_NUM2INT(val); break;
  default:
    rb_raise(rb_eArgError, "unknown type for val: %d", TYPE(val));
  }

  return retval;
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
  res->sem_id = initialize_single_semaphore(res->key, SEM_DEFAULT_PERMISSIONS, 0);

  return self;
}

VALUE
semian_simple_integer_increment(int argc, VALUE *argv, VALUE self)
{
  semian_simple_integer_t *res;
  TypedData_Get_Struct(self, semian_simple_integer_t, &semian_simple_integer_type, res);

  // This is definitely the worst API ever.
  // https://silverhammermba.github.io/emberb/c/#parsing-arguments
  VALUE val;
  rb_scan_args(argc, argv, "01", &val);

  int value = check_increment_arg(val);
  if (perform_semop(res->sem_id, 0, value, 0, NULL) == -1) {
    rb_raise(eInternal, "error incrementing simple integer, errno: %d (%s)", errno, strerror(errno));
  }

  // Return the current value, but know that there is a race condition here:
  // It's not necessarily the same value after incrementing above, since
  // semop() doesn't return the modified value.
  int retval = get_sem_val(res->sem_id, 0);
  if (retval == -1) {
    rb_raise(eInternal, "error getting simple integer, errno: %d (%s)", errno, strerror(errno));
  }

  return RB_INT2NUM(retval);
}

VALUE
semian_simple_integer_reset(VALUE self)
{
  semian_simple_integer_t *res;
  TypedData_Get_Struct(self, semian_simple_integer_t, &semian_simple_integer_type, res);

  if (set_sem_val(res->sem_id, 0, 0) == -1) {
    rb_raise(eInternal, "error resetting simple integer, errno: %d (%s)", errno, strerror(errno));
  }

  return Qnil;
}

VALUE
semian_simple_integer_value_get(VALUE self)
{
  semian_simple_integer_t *res;
  TypedData_Get_Struct(self, semian_simple_integer_t, &semian_simple_integer_type, res);

  int val = get_sem_val(res->sem_id, 0);
  if (val == -1) {
    rb_raise(eInternal, "error getting simple integer, errno: %d (%s)", errno, strerror(errno));
  }

  return RB_INT2NUM(val);
}

VALUE
semian_simple_integer_value_set(VALUE self, VALUE val)
{
  semian_simple_integer_t *res;
  TypedData_Get_Struct(self, semian_simple_integer_t, &semian_simple_integer_type, res);

  VALUE to_i = rb_funcall(val, rb_intern("to_i"), 0);
  int value = RB_NUM2INT(to_i);
  if (set_sem_val(res->sem_id, 0, value) == -1) {
    rb_raise(eInternal, "error setting simple integer, errno: %d (%s)", errno, strerror(errno));
  }

  return Qnil;
}
