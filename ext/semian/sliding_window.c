#include "sliding_window.h"

#include <errno.h>
#include <sys/ipc.h>
#include <sys/shm.h>
#include "util.h"

static const rb_data_type_t semian_simple_sliding_window_type;

static semian_simple_sliding_window_shared_t* get_window(uint64_t key) {
  const int permissions = 0664;
  int shmid = shmget(key, sizeof(int), IPC_CREAT | permissions);
  if (shmid == -1) {
    rb_raise(rb_eArgError, "could not create shared memory (%s)", strerror(errno));
  }

  void *val = shmat(shmid, NULL, 0);
  if (val == (void*)-1) {
    rb_raise(rb_eArgError, "could not get shared memory (%s)", strerror(errno));
  }

  return (semian_simple_sliding_window_shared_t*)val;
}

static int check_max_size_arg(VALUE max_size)
{
  int retval = -1;
  switch (TYPE(max_size)) {
  case T_NIL:
    retval = SLIDING_WINDOW_MAX_SIZE; break;
  case T_FLOAT:
    rb_warn("semian sliding window max_size is a float, converting to fixnum");
    retval = (int)(RFLOAT_VALUE(max_size)); break;
  default:
    retval = RB_NUM2INT(max_size); break;
  }

  if (retval <= 0) {
    rb_raise(rb_eArgError, "max_size must be greater than zero");
  } else if (retval > SLIDING_WINDOW_MAX_SIZE) {
    rb_raise(rb_eArgError, "max_size cannot be greater than %d", SLIDING_WINDOW_MAX_SIZE);
  }

  return retval;
}

void Init_SlidingWindow() {
  dprintf("Init_SlidingWindow");

  VALUE cSemian = rb_const_get(rb_cObject, rb_intern("Semian"));
  VALUE cSimple = rb_const_get(cSemian, rb_intern("Simple"));
  VALUE cSlidingWindow = rb_const_get(cSimple, rb_intern("SlidingWindow"));

  rb_define_alloc_func(cSlidingWindow, semian_simple_sliding_window_alloc);
  rb_define_method(cSlidingWindow, "initialize_sliding_window", semian_simple_sliding_window_initialize, 2);
  rb_define_method(cSlidingWindow, "size", semian_simple_sliding_window_size, 0);
  rb_define_method(cSlidingWindow, "max_size", semian_simple_sliding_window_max_size, 0);
  rb_define_method(cSlidingWindow, "values", semian_simple_sliding_window_values, 0);
  rb_define_method(cSlidingWindow, "last", semian_simple_sliding_window_last, 0);
  rb_define_method(cSlidingWindow, "<<", semian_simple_sliding_window_push, 1);
  rb_define_method(cSlidingWindow, "destroy", semian_simple_sliding_window_clear, 0);
  rb_define_method(cSlidingWindow, "reject!", semian_simple_sliding_window_reject, 0);
}

VALUE semian_simple_sliding_window_alloc(VALUE klass) {
  semian_simple_sliding_window_t *res;
  VALUE obj = TypedData_Make_Struct(klass, semian_simple_sliding_window_t, &semian_simple_sliding_window_type, res);
  return obj;
}

VALUE semian_simple_sliding_window_initialize(VALUE self, VALUE name, VALUE max_size) {
  dprintf("semian_simple_sliding_window_initialize");

  semian_simple_sliding_window_t *res;
  TypedData_Get_Struct(self, semian_simple_sliding_window_t, &semian_simple_sliding_window_type, res);

  const char *id_str = check_id_arg(name);
  res->key = generate_key(id_str);

  semian_simple_sliding_window_shared_t *window = get_window(res->key);
  window->max_size = check_max_size_arg(max_size);
  window->length = 0;
  window->start = 0;
  window->end = 0;

  dprintf("  key:%lu addr:0x%p max_size:%d length:%d start:%d end:%d", res->key, window, window->max_size, window->length, window->start, window->end);

  return self;
}

VALUE semian_simple_sliding_window_size(VALUE self) {
  dprintf("semian_simple_sliding_window_size");

  semian_simple_sliding_window_t *res;
  TypedData_Get_Struct(self, semian_simple_sliding_window_t, &semian_simple_sliding_window_type, res);

  semian_simple_sliding_window_shared_t *window = get_window(res->key);
  dprintf("  key:%lu addr:0x%p max_size:%d length:%d start:%d end:%d", res->key, window, window->max_size, window->length, window->start, window->end);

  return RB_INT2NUM(window->length);
}

VALUE semian_simple_sliding_window_max_size(VALUE self) {
  dprintf("semian_simple_sliding_window_max_size");

  semian_simple_sliding_window_t *res;
  TypedData_Get_Struct(self, semian_simple_sliding_window_t, &semian_simple_sliding_window_type, res);

  semian_simple_sliding_window_shared_t *window = get_window(res->key);
  dprintf("  key:%lu addr:0x%p max_size:%d length:%d start:%d end:%d", res->key, window, window->max_size, window->length, window->start, window->end);

  return RB_INT2NUM(window->max_size);
}

VALUE semian_simple_sliding_window_values(VALUE self) {
  dprintf("semian_simple_sliding_window_values");

  semian_simple_sliding_window_t *res;
  TypedData_Get_Struct(self, semian_simple_sliding_window_t, &semian_simple_sliding_window_type, res);
  semian_simple_sliding_window_shared_t *window = get_window(res->key);

  VALUE retval = rb_ary_new_capa(window->length);
  for (int i = 0; i < window->length; ++i) {
    int index = (window->start + i) % window->max_size;
    int value = window->data[index];
    dprintf("  i:%d index: %d value:%d max_size:%d length:%d start:%d end:%d", i, index, value, window->max_size, window->length, window->start, window->end);
    rb_ary_store(retval, i, RB_INT2NUM(value));
  }

  return retval;
}

VALUE semian_simple_sliding_window_last(VALUE self) {
  dprintf("semian_simple_sliding_window_last");

  semian_simple_sliding_window_t *res;
  TypedData_Get_Struct(self, semian_simple_sliding_window_t, &semian_simple_sliding_window_type, res);
  semian_simple_sliding_window_shared_t *window = get_window(res->key);

  int index = (window->start + window->length - 1) % window->max_size;
  dprintf("  index:%d last:%d", index, window->data[index]);

  return RB_INT2NUM(window->data[index]);
}

VALUE semian_simple_sliding_window_clear(VALUE self) {
  dprintf("semian_simple_sliding_window_clear");

  semian_simple_sliding_window_t *res;
  TypedData_Get_Struct(self, semian_simple_sliding_window_t, &semian_simple_sliding_window_type, res);
  semian_simple_sliding_window_shared_t *window = get_window(res->key);

  window->length = 0;
  window->start = 0;
  window->end = 0;

  return self;
}

VALUE semian_simple_sliding_window_reject(VALUE self) {
  dprintf("semian_simple_sliding_window_reject");

  rb_need_block();

  semian_simple_sliding_window_t *res;
  TypedData_Get_Struct(self, semian_simple_sliding_window_t, &semian_simple_sliding_window_type, res);
  semian_simple_sliding_window_shared_t *window = get_window(res->key);

  // Store these values because we're going to be modifying the buffer.
  int start = window->start;
  int length = window->length;

  int cleared = 0;
  for (int i = 0; i < length; ++i) {
    int index = (start + i) % length;
    int value = window->data[index];
    dprintf("  i:%d index: %d value:%d max_size:%d length:%d start:%d end:%d", i, index, value, window->max_size, window->length, window->start, window->end);
    VALUE y = rb_yield(RB_INT2NUM(value));
    if (RTEST(y)) {
      if (cleared++ != i) {
        rb_raise(rb_eArgError, "reject! must delete monotonically");
      }
      window->start = (window->start + 1) % window->length;
      window->length--;
      dprintf("  Removed index:%d (val:%d)", i, value);
    }
  }

  return self;
}

VALUE semian_simple_sliding_window_push(VALUE self, VALUE value) {
  dprintf("semian_simple_sliding_window_push");

  semian_simple_sliding_window_t *res;
  TypedData_Get_Struct(self, semian_simple_sliding_window_t, &semian_simple_sliding_window_type, res);

  semian_simple_sliding_window_shared_t *window = get_window(res->key);
  if (window->length == window->max_size) {
    window->length--;
    window->start = (window->start + 1) % window->max_size;
  }

  const int index = window->end;
  window->length++;
  window->data[index] = RB_NUM2INT(value);
  window->end = (window->end + 1) % window->max_size;

  dprintf("  Pushed val:%d index:%d max_size:%d length:%d start:%d end:%d", RB_NUM2INT(value), index, window->max_size, window->length, window->start, window->end);

  return self;
}
