#include "semian_shared_memory_object.h"

typedef struct {
  int value;
} semian_atomic_int;

static void semian_atomic_integer_bind_init_fn (size_t byte_size, void *dest, void *prev_data, size_t prev_data_byte_size, int prev_mem_attach_count);
static VALUE semian_atomic_integer_bind_init_fn_wrapper(VALUE self);
static VALUE semian_atomic_integer_get_value(VALUE self);
static VALUE semian_atomic_integer_set_value(VALUE self, VALUE num);
static VALUE semian_atomic_integer_increase_by(VALUE self, VALUE num);

static void
semian_atomic_integer_bind_init_fn (size_t byte_size, void *dest, void *prev_data, size_t prev_data_byte_size, int prev_mem_attach_count)
{
  semian_atomic_int *ptr = dest;
  semian_atomic_int *old = prev_data;
  if (prev_mem_attach_count){
    if (prev_data){
      ptr->value = old->value;
    } // else copy nothing, data is same size and no need to copy
  } else {
    ptr->value=0;
  }
}

static VALUE
semian_atomic_integer_bind_init_fn_wrapper(VALUE self)
{
  semian_shm_object *ptr;
  TypedData_Get_Struct(self, semian_shm_object, &semian_shm_object_type, ptr);
  ptr->object_init_fn = &semian_atomic_integer_bind_init_fn;
  return self;
}

static VALUE
semian_atomic_integer_get_value(VALUE self)
{
  semian_shm_object *ptr;
  TypedData_Get_Struct(self, semian_shm_object, &semian_shm_object_type, ptr);

  // check shared memory for NULL
  if (0 == ptr->shm_address)
    return Qnil;

  semian_shm_object_check_and_resize_if_needed(self);
  if (!semian_shm_object_lock(self))
    return Qnil;

  int value = ((semian_atomic_int *)(ptr->shm_address))->value;
  semian_shm_object_unlock(self);
  return INT2NUM(value);
}

static VALUE
semian_atomic_integer_set_value(VALUE self, VALUE num)
{
  semian_shm_object *ptr;
  TypedData_Get_Struct(self, semian_shm_object, &semian_shm_object_type, ptr);

  if (0 == ptr->shm_address)
    return Qnil;

  if (TYPE(num) != T_FIXNUM && TYPE(num) != T_FLOAT)
    return Qnil;
  semian_shm_object_check_and_resize_if_needed(self);
  if (!semian_shm_object_lock(self))
    return Qnil;

  ((semian_atomic_int *)(ptr->shm_address))->value = NUM2INT(num);

  semian_shm_object_unlock(self);
  return num;
}

static VALUE
semian_atomic_integer_increase_by(VALUE self, VALUE num)
{
  semian_shm_object *ptr;
  TypedData_Get_Struct(self, semian_shm_object, &semian_shm_object_type, ptr);

  if (0 == ptr->shm_address)
    return Qnil;

  if (TYPE(num) != T_FIXNUM && TYPE(num) != T_FLOAT)
    return Qnil;
  semian_shm_object_check_and_resize_if_needed(self);
  if (!semian_shm_object_lock(self))
    return Qnil;

  ((semian_atomic_int *)(ptr->shm_address))->value += NUM2INT(num);

  semian_shm_object_unlock(self);
  return self;
}

void
Init_semian_atomic_integer (void)
{
  // Bind methods to AtomicInteger
  VALUE cSemianModule = rb_const_get(rb_cObject, rb_intern("Semian"));
  VALUE cAtomicInteger = rb_const_get(cSemianModule, rb_intern("AtomicInteger"));

  rb_define_method(cAtomicInteger, "bind_init_fn", semian_atomic_integer_bind_init_fn_wrapper, 0);
  rb_define_method(cAtomicInteger, "value", semian_atomic_integer_get_value, 0);
  rb_define_method(cAtomicInteger, "value=", semian_atomic_integer_set_value, 1);
  rb_define_method(cAtomicInteger, "increase_by", semian_atomic_integer_increase_by, 1);
}
