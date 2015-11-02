#include "semian_shared_memory_object.h"

typedef struct {
  int max_window_size;
  int window_size;
  long window[];
} semian_sliding_window;

static void semian_sliding_window_bind_init_fn (size_t byte_size, void *dest, void *prev_data, size_t prev_data_byte_size, int prev_mem_attach_count);
static VALUE semian_sliding_window_bind_init_fn_wrapper(VALUE self);
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
semian_sliding_window_bind_init_fn (size_t byte_size, void *dest, void *prev_data, size_t prev_data_byte_size, int prev_mem_attach_count)
{
  semian_sliding_window *ptr = dest;
  semian_sliding_window *old = prev_data;

  // Logic to initialize: initialize to 0 only if you're the first to attach (else body)
  // Otherwise, copy previous data into new data
  if (prev_mem_attach_count) {
    if (prev_data) {
      // transfer data over
      ptr->max_window_size = (byte_size-2*sizeof(int))/sizeof(long);
      ptr->window_size = fmin(ptr->max_window_size, old->window_size);

      // Copy the most recent ptr->shm_address->window_size numbers to new memory
      memcpy(&(ptr->window),
            ((long *)(&(old->window[0])))+old->window_size-ptr->window_size,
            ptr->window_size * sizeof(long));
    } // else copy nothing, data is same size and no need to copy
  } else {
    semian_sliding_window *data = dest;
    data->max_window_size = (byte_size-2*sizeof(int))/sizeof(long);
    data->window_size = 0;
    for (int i=0; i< data->window_size; ++i)
      data->window[i]=0;
  }
}

static VALUE
semian_sliding_window_bind_init_fn_wrapper(VALUE self)
{
  semian_shm_object *ptr;
  TypedData_Get_Struct(self, semian_shm_object, &semian_shm_object_type, ptr);
  ptr->object_init_fn = &semian_sliding_window_bind_init_fn;
  return self;
}

static VALUE
semian_sliding_window_size(VALUE self)
{
  semian_shm_object *ptr;
  TypedData_Get_Struct(self, semian_shm_object, &semian_shm_object_type, ptr);
  if (0 == ptr->shm_address)
    return Qnil;
  semian_shm_object_check_and_resize_if_needed(self);
  if (!semian_shm_object_lock(self))
    return Qnil;
  int window_size = ((semian_sliding_window *)(ptr->shm_address))->window_size;
  semian_shm_object_unlock(self);
  return INT2NUM(window_size);
}

static VALUE
semian_sliding_window_max_size(VALUE self)
{
  semian_shm_object *ptr;
  TypedData_Get_Struct(self, semian_shm_object, &semian_shm_object_type, ptr);
  if (0 == ptr->shm_address)
    return Qnil;
  semian_shm_object_check_and_resize_if_needed(self);
  if (!semian_shm_object_lock(self))
    return Qnil;
  int max_length = ((semian_sliding_window *)(ptr->shm_address))->max_window_size;
  semian_shm_object_unlock(self);
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
  semian_shm_object_check_and_resize_if_needed(self);
  if (!semian_shm_object_lock(self))
    return Qnil;

  semian_sliding_window *data = ptr->shm_address;
  if (data->window_size == data->max_window_size) {
    for (int i=1; i< data->max_window_size; ++i){
      data->window[i-1] = data->window[i];
    }
    --(data->window_size);
  }
  data->window[(data->window_size)] = NUM2LONG(num);
  ++(data->window_size);
  semian_shm_object_unlock(self);
  return self;
}

static VALUE
semian_sliding_window_pop_back(VALUE self)
{
  semian_shm_object *ptr;
  TypedData_Get_Struct(self, semian_shm_object, &semian_shm_object_type, ptr);
  if (0 == ptr->shm_address)
    return Qnil;
  semian_shm_object_check_and_resize_if_needed(self);
  if (!semian_shm_object_lock(self))
    return Qnil;

  VALUE retval;
  semian_sliding_window *data = ptr->shm_address;
  if (0 == data->window_size)
    retval = Qnil;
  else {
    retval = LONG2NUM(data->window[data->window_size-1]);
    --(data->window_size);
  }

  semian_shm_object_unlock(self);
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
  semian_shm_object_check_and_resize_if_needed(self);
  if (!semian_shm_object_lock(self))
    return Qnil;

  long val = NUM2LONG(num);
  semian_sliding_window *data = ptr->shm_address;

  int i=data->window_size;
  for (; i>0; --i)
    data->window[i]=data->window[i-1];

  data->window[0] = val;
  ++(data->window_size);
  if (data->window_size>data->max_window_size)
    data->window_size=data->max_window_size;

  semian_shm_object_unlock(self);
  return self;
}

static VALUE
semian_sliding_window_pop_front(VALUE self)
{
  semian_shm_object *ptr;
  TypedData_Get_Struct(self, semian_shm_object, &semian_shm_object_type, ptr);
  if (0 == ptr->shm_address)
    return Qnil;
  semian_shm_object_check_and_resize_if_needed(self);
  if (!semian_shm_object_lock(self))
    return Qnil;

  VALUE retval;
  semian_sliding_window *data = ptr->shm_address;
  if (0 >= data->window_size)
    retval = Qnil;
  else {
    retval = LONG2NUM(data->window[0]);
    for (int i=0; i<data->window_size-1; ++i)
      data->window[i]=data->window[i+1];
    --(data->window_size);
  }

  semian_shm_object_unlock(self);
  return retval;
}

static VALUE
semian_sliding_window_clear(VALUE self)
{
  semian_shm_object *ptr;
  TypedData_Get_Struct(self, semian_shm_object, &semian_shm_object_type, ptr);
  if (0 == ptr->shm_address)
    return Qnil;
  semian_shm_object_check_and_resize_if_needed(self);
  if (!semian_shm_object_lock(self))
    return Qnil;
  semian_sliding_window *data = ptr->shm_address;
  data->window_size=0;

  semian_shm_object_unlock(self);
  return self;
}

static VALUE
semian_sliding_window_first(VALUE self)
{
  semian_shm_object *ptr;
  TypedData_Get_Struct(self, semian_shm_object, &semian_shm_object_type, ptr);
  if (0 == ptr->shm_address)
    return Qnil;
  semian_shm_object_check_and_resize_if_needed(self);
  if (!semian_shm_object_lock(self))
    return Qnil;

  VALUE retval;
  semian_sliding_window *data = ptr->shm_address;
  if (data->window_size >=1)
    retval = LONG2NUM(data->window[0]);
  else
    retval = Qnil;

  semian_shm_object_unlock(self);
  return retval;
}

static VALUE
semian_sliding_window_last(VALUE self)
{
  semian_shm_object *ptr;
  TypedData_Get_Struct(self, semian_shm_object, &semian_shm_object_type, ptr);
  if (0 == ptr->shm_address)
    return Qnil;
  semian_shm_object_check_and_resize_if_needed(self);
  if (!semian_shm_object_lock(self))
    return Qnil;

  VALUE retval;
  semian_sliding_window *data = ptr->shm_address;
  if (data->window_size > 0)
    retval = LONG2NUM(data->window[data->window_size-1]);
  else
    retval = Qnil;

  semian_shm_object_unlock(self);
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

  if (!semian_shm_object_lock(self))
    return Qnil;

  semian_sliding_window *data_copy = NULL;
  size_t byte_size=0;
  int prev_mem_attach_count = 0;
  if (-1 != ptr->shmid && (void *)-1 != ptr->shm_address) {
    data_copy = malloc(ptr->byte_size);
    memcpy(data_copy,ptr->shm_address,ptr->byte_size);
    byte_size = ptr->byte_size;
    struct shmid_ds shm_info;
    if (-1 != shmctl(ptr->shmid, IPC_STAT, &shm_info)){
      prev_mem_attach_count = shm_info.shm_nattch;
    }
  }

  semian_shm_object_delete_memory_inner(ptr, 1, self, NULL);
  ptr->byte_size = 2*sizeof(int) + NUM2INT(size) * sizeof(long);
  semian_shm_object_unlock(self);

  semian_shm_object_acquire_memory(self, LONG2FIX(ptr->permissions), Qtrue);
  if (!semian_shm_object_lock(self))
    return Qnil;
  ptr->object_init_fn(ptr->byte_size, ptr->shm_address, data_copy, byte_size, prev_mem_attach_count);
  semian_shm_object_unlock(self);

  return self;
}

void
Init_semian_sliding_window (void)
{
  VALUE cSemianModule = rb_const_get(rb_cObject, rb_intern("Semian"));
  VALUE cSlidingWindow = rb_const_get(cSemianModule, rb_intern("SysVSlidingWindow"));

  rb_define_method(cSlidingWindow, "bind_init_fn", semian_sliding_window_bind_init_fn_wrapper, 0);
  rb_define_method(cSlidingWindow, "size", semian_sliding_window_size, 0);
  rb_define_method(cSlidingWindow, "max_size", semian_sliding_window_max_size, 0);
  rb_define_method(cSlidingWindow, "resize_to", semian_sliding_window_resize_to, 1);
  rb_define_method(cSlidingWindow, "<<", semian_sliding_window_push_back, 1);
  rb_define_method(cSlidingWindow, "push", semian_sliding_window_push_back, 1);
  rb_define_method(cSlidingWindow, "pop", semian_sliding_window_pop_back, 0);
  rb_define_method(cSlidingWindow, "shift", semian_sliding_window_pop_front, 0);
  rb_define_method(cSlidingWindow, "unshift", semian_sliding_window_push_front, 1);
  rb_define_method(cSlidingWindow, "clear", semian_sliding_window_clear, 0);
  rb_define_method(cSlidingWindow, "first", semian_sliding_window_first, 0);
  rb_define_method(cSlidingWindow, "last", semian_sliding_window_last, 0);
}
