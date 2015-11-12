#include "semian_shared_memory_object.h"

typedef struct {
  int value;
} semian_int;

static void semian_integer_bind_init_fn (size_t byte_size, void *dest, void *prev_data, size_t prev_data_byte_size, int prev_mem_attach_count);
static VALUE semian_integer_bind_init_fn_wrapper(VALUE self);
static VALUE semian_integer_get_value(VALUE self);
static VALUE semian_integer_set_value(VALUE self, VALUE num);
static VALUE semian_integer_increment(int argc, VALUE *argv, VALUE self);

static void
semian_integer_bind_init_fn (size_t byte_size, void *dest, void *prev_data, size_t prev_data_byte_size, int prev_mem_attach_count)
{
  semian_int *ptr = dest;
  semian_int *old = prev_data;
  if (prev_mem_attach_count){
    if (prev_data){
      ptr->value = old->value;
    } // else copy nothing, data is same size and no need to copy
  } else {
    ptr->value=0;
  }
}

static VALUE
semian_integer_bind_init_fn_wrapper(VALUE self)
{
  semian_shm_object *ptr;
  TypedData_Get_Struct(self, semian_shm_object, &semian_shm_object_type, ptr);
  ptr->object_init_fn = &semian_integer_bind_init_fn;
  return self;
}

static VALUE
semian_integer_get_value(VALUE self)
{
  semian_shm_object *ptr;
  TypedData_Get_Struct(self, semian_shm_object, &semian_shm_object_type, ptr);

  // check shared memory for NULL
  if (0 == ptr->shm_address)
    return Qnil;

  semian_shm_object_check_and_resize_if_needed(self);
  if (!semian_shm_object_lock(self))
    return Qnil;

  int value = ((semian_int *)(ptr->shm_address))->value;
  semian_shm_object_unlock(self);
  return INT2NUM(value);
}

static VALUE
semian_integer_set_value(VALUE self, VALUE num)
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

  ((semian_int *)(ptr->shm_address))->value = NUM2INT(num);

  semian_shm_object_unlock(self);
  return num;
}

static VALUE
semian_integer_reset(VALUE self)
{
  return semian_integer_set_value(self, INT2NUM(0));
}

static VALUE
semian_integer_increment(int argc, VALUE *argv, VALUE self)
{
  VALUE num;
  rb_scan_args(argc, argv, "01", &num);
  if (num == Qnil)
    num = INT2NUM(1);

  semian_shm_object *ptr;
  TypedData_Get_Struct(self, semian_shm_object, &semian_shm_object_type, ptr);

  if (0 == ptr->shm_address)
    return Qnil;

  if (TYPE(num) != T_FIXNUM && TYPE(num) != T_FLOAT)
    return Qnil;
  semian_shm_object_check_and_resize_if_needed(self);
  if (!semian_shm_object_lock(self))
    return Qnil;

  ((semian_int *)(ptr->shm_address))->value += NUM2INT(num);

  semian_shm_object_unlock(self);
  return self;
}

void
Init_semian_integer (void)
{
  // Bind methods to Integer
  VALUE cSemianModule = rb_const_get(rb_cObject, rb_intern("Semian"));
  VALUE cSysVSharedMemory = rb_const_get(cSemianModule, rb_intern("SysVSharedMemory"));
  VALUE cSysVModule = rb_const_get(cSemianModule, rb_intern("SysV"));
  VALUE cInteger = rb_const_get(cSysVModule, rb_intern("Integer"));

  semian_shm_object_replace_alloc(cSysVSharedMemory, cInteger);

  rb_define_method(cInteger, "bind_init_fn", semian_integer_bind_init_fn_wrapper, 0);
  rb_define_method(cInteger, "value", semian_integer_get_value, 0);
  rb_define_method(cInteger, "value=", semian_integer_set_value, 1);
  rb_define_method(cInteger, "reset", semian_integer_reset, 0);
  rb_define_method(cInteger, "increment", semian_integer_increment, -1);
}
