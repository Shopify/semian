#include "semian_shared_memory_object.h"

typedef struct {
  int max_window_size;
  int window_size;
  long window[];
} semian_sliding_window;

static void semian_sliding_window_initialize_memory (size_t byte_size, void *dest, void *prev_data, size_t prev_data_byte_size);
static VALUE semian_sliding_window_bind_initialize_memory_callback(VALUE self);
static VALUE semian_sliding_window_size(VALUE self);
static VALUE semian_sliding_window_max_size(VALUE self);
static VALUE semian_sliding_window_push_back(VALUE self, VALUE num);
static VALUE semian_sliding_window_pop_back(VALUE self);
static VALUE semian_sliding_window_push_front(VALUE self, VALUE num);
static VALUE semian_sliding_window_pop_front(VALUE self);
static VALUE semian_sliding_window_clear(VALUE self);
static VALUE semian_sliding_window_first(VALUE self);
static VALUE semian_sliding_window_last(VALUE self);
static VALUE semian_sliding_window_resize_to(VALUE self, VALUE size);

static void
semian_sliding_window_initialize_memory (size_t byte_size, void *dest, void *prev_data, size_t prev_data_byte_size)
{
  semian_sliding_window *ptr = dest;
  semian_sliding_window *old = prev_data;

  if (prev_data) {
    ptr->max_window_size = (byte_size - 2 * sizeof(int)) / sizeof(long);
    ptr->window_size = fmin(ptr->max_window_size, old->window_size);

    // Copy the most recent ptr->shm_address->window_size numbers to new memory
    memcpy(&(ptr->window),
           ((long *)(&(old->window[0]))) + old->window_size - ptr->window_size,
           ptr->window_size * sizeof(long));
  } else {
    semian_sliding_window *data = dest;
    data->max_window_size = (byte_size - 2 * sizeof(int)) / sizeof(long);
    data->window_size = 0;
    for (int i = 0; i < data->window_size; ++i)
      data->window[i] = 0;
  }
}

static VALUE
semian_sliding_window_bind_initialize_memory_callback(VALUE self)
{
  semian_shm_object *ptr;
  TypedData_Get_Struct(self, semian_shm_object, &semian_shm_object_type, ptr);
  ptr->initialize_memory = &semian_sliding_window_initialize_memory;
  return self;
}

static VALUE
semian_sliding_window_size(VALUE self)
{
  semian_shm_object *ptr;
  TypedData_Get_Struct(self, semian_shm_object, &semian_shm_object_type, ptr);
  if (0 == ptr->shm_address)
    return Qnil;
  int window_size = ((semian_sliding_window *)(ptr->shm_address))->window_size;
  return INT2NUM(window_size);
}

static VALUE
semian_sliding_window_max_size(VALUE self)
{
  semian_shm_object *ptr;
  TypedData_Get_Struct(self, semian_shm_object, &semian_shm_object_type, ptr);
  if (0 == ptr->shm_address)
    return Qnil;
  int max_length = ((semian_sliding_window *)(ptr->shm_address))->max_window_size;
  return INT2NUM(max_length);
}

static VALUE
semian_sliding_window_push_back(VALUE self, VALUE num)
{
  semian_shm_object *ptr;
  TypedData_Get_Struct(self, semian_shm_object, &semian_shm_object_type, ptr);
  if (0 == ptr->shm_address)
    return Qnil;
  if (TYPE(num) != T_FIXNUM && TYPE(num) != T_FLOAT && TYPE(num) != T_BIGNUM)
    return Qnil;

  semian_sliding_window *data = ptr->shm_address;
  if (data->window_size == data->max_window_size) {
    for (int i = 1; i < data->max_window_size; ++i){
      data->window[i - 1] = data->window[i];
    }
    --(data->window_size);
  }
  data->window[(data->window_size)] = NUM2LONG(num);
  ++(data->window_size);
  return self;
}

static VALUE
semian_sliding_window_pop_back(VALUE self)
{
  semian_shm_object *ptr;
  TypedData_Get_Struct(self, semian_shm_object, &semian_shm_object_type, ptr);
  if (0 == ptr->shm_address)
    return Qnil;

  VALUE retval;
  semian_sliding_window *data = ptr->shm_address;
  if (0 == data->window_size)
    retval = Qnil;
  else {
    retval = LONG2NUM(data->window[data->window_size - 1]);
    --(data->window_size);
  }
  return retval;
}

static VALUE
semian_sliding_window_push_front(VALUE self, VALUE num)
{
  semian_shm_object *ptr;
  TypedData_Get_Struct(self, semian_shm_object, &semian_shm_object_type, ptr);
  if (0 == ptr->shm_address)
    return Qnil;
  if (TYPE(num) != T_FIXNUM && TYPE(num) != T_FLOAT && TYPE(num) != T_BIGNUM)
    return Qnil;

  long val = NUM2LONG(num);
  semian_sliding_window *data = ptr->shm_address;

  for (int i=data->window_size; i > 0; --i)
    data->window[i] = data->window[i - 1];

  data->window[0] = val;
  ++(data->window_size);
  if (data->window_size > data->max_window_size)
    data->window_size=data->max_window_size;

  return self;
}

static VALUE
semian_sliding_window_pop_front(VALUE self)
{
  semian_shm_object *ptr;
  TypedData_Get_Struct(self, semian_shm_object, &semian_shm_object_type, ptr);
  if (0 == ptr->shm_address)
    return Qnil;

  VALUE retval;
  semian_sliding_window *data = ptr->shm_address;
  if (0 >= data->window_size)
    retval = Qnil;
  else {
    retval = LONG2NUM(data->window[0]);
    for (int i = 0; i < data->window_size - 1; ++i)
      data->window[i] = data->window[i + 1];
    --(data->window_size);
  }

  return retval;
}

static VALUE
semian_sliding_window_clear(VALUE self)
{
  semian_shm_object *ptr;
  TypedData_Get_Struct(self, semian_shm_object, &semian_shm_object_type, ptr);
  if (0 == ptr->shm_address)
    return Qnil;
  semian_sliding_window *data = ptr->shm_address;
  data->window_size = 0;

  return self;
}

static VALUE
semian_sliding_window_first(VALUE self)
{
  semian_shm_object *ptr;
  TypedData_Get_Struct(self, semian_shm_object, &semian_shm_object_type, ptr);
  if (0 == ptr->shm_address)
    return Qnil;

  VALUE retval;
  semian_sliding_window *data = ptr->shm_address;
  if (data->window_size >= 1)
    retval = LONG2NUM(data->window[0]);
  else
    retval = Qnil;

  return retval;
}

static VALUE
semian_sliding_window_last(VALUE self)
{
  semian_shm_object *ptr;
  TypedData_Get_Struct(self, semian_shm_object, &semian_shm_object_type, ptr);
  if (0 == ptr->shm_address)
    return Qnil;

  VALUE retval;
  semian_sliding_window *data = ptr->shm_address;
  if (data->window_size > 0)
    retval = LONG2NUM(data->window[data->window_size - 1]);
  else
    retval = Qnil;

  return retval;
}

static VALUE
semian_sliding_window_resize_to(VALUE self, VALUE size) {
  semian_shm_object *ptr;
  TypedData_Get_Struct(self, semian_shm_object, &semian_shm_object_type, ptr);

  if (TYPE(size) != T_FIXNUM && TYPE(size) != T_FLOAT)
    return Qnil;
  if (NUM2INT(size) <= 0)
    rb_raise(rb_eArgError, "size must be larger than 0");

  ptr->byte_size = 2 * sizeof(int) + NUM2INT(size) * sizeof(long);
  semian_shm_object_synchronize_memory_and_size(self, Qtrue);

  return self;
}

static VALUE
semian_sliding_window_calculate_byte_size(VALUE klass, VALUE size)
{
  return INT2NUM(2 * sizeof(int) + NUM2INT(size) * sizeof(long));
}

void
Init_semian_sliding_window (void)
{
  VALUE cSemianModule = rb_const_get(rb_cObject, rb_intern("Semian"));
  VALUE cSysVModule = rb_const_get(cSemianModule, rb_intern("SysV"));
  VALUE cSysVSharedMemory = rb_const_get(cSemianModule, rb_intern("SysVSharedMemory"));
  VALUE cSlidingWindow = rb_const_get(cSysVModule, rb_intern("SlidingWindow"));

  semian_shm_object_replace_alloc(cSysVSharedMemory, cSlidingWindow);

  rb_define_private_method(cSlidingWindow, "bind_initialize_memory_callback", semian_sliding_window_bind_initialize_memory_callback, 0);
  define_method_with_synchronize(cSlidingWindow, "size", semian_sliding_window_size, 0);
  define_method_with_synchronize(cSlidingWindow, "max_size", semian_sliding_window_max_size, 0);
  define_method_with_synchronize(cSlidingWindow, "resize_to", semian_sliding_window_resize_to, 1);
  define_method_with_synchronize(cSlidingWindow, "<<", semian_sliding_window_push_back, 1);
  define_method_with_synchronize(cSlidingWindow, "push", semian_sliding_window_push_back, 1);
  define_method_with_synchronize(cSlidingWindow, "pop", semian_sliding_window_pop_back, 0);
  define_method_with_synchronize(cSlidingWindow, "shift", semian_sliding_window_pop_front, 0);
  define_method_with_synchronize(cSlidingWindow, "unshift", semian_sliding_window_push_front, 1);
  define_method_with_synchronize(cSlidingWindow, "clear", semian_sliding_window_clear, 0);
  define_method_with_synchronize(cSlidingWindow, "first", semian_sliding_window_first, 0);
  define_method_with_synchronize(cSlidingWindow, "last", semian_sliding_window_last, 0);
  rb_define_method(cSlidingWindow, "calculate_byte_size", semian_sliding_window_calculate_byte_size, 1);
}
