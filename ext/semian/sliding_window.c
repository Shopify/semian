#include "sliding_window.h"

#include "util.h"
#include "sysv_semaphores.h"
#include "sysv_shared_memory.h"

void
semian_simple_sliding_window_dfree(void* ptr)
{
  semian_simple_sliding_window_t* res = (semian_simple_sliding_window_t*)ptr;
  free_shared_memory(res->shmem);
}

size_t
semian_simple_sliding_window_dsize(const void* ptr)
{
  return sizeof(semian_simple_sliding_window_t);
}

static const rb_data_type_t semian_simple_sliding_window_type = {
  .wrap_struct_name = "semian_simple_sliding_window",
  .function = {
    .dmark = NULL,
    .dfree = semian_simple_sliding_window_dfree,
    .dsize = semian_simple_sliding_window_dsize,
  },
  .data = NULL,
  .flags = RUBY_TYPED_FREE_IMMEDIATELY,
};

static void init_fn(void* ptr)
{
  semian_simple_sliding_window_shared_t* res = (semian_simple_sliding_window_shared_t*)ptr;
  res->max_size = 0;
  res->length = 0;
  res->start = 0;
  res->end = 0;
}

static int
check_max_size_arg(VALUE max_size)
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

// Get the C object for a Ruby instance
static semian_simple_sliding_window_t*
get_object(VALUE self)
{
  semian_simple_sliding_window_t *res;
  TypedData_Get_Struct(self, semian_simple_sliding_window_t, &semian_simple_sliding_window_type, res);
  return res;
}

void
Init_SlidingWindow()
{
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

VALUE
semian_simple_sliding_window_alloc(VALUE klass)
{
  semian_simple_sliding_window_t *res;
  VALUE obj = TypedData_Make_Struct(klass, semian_simple_sliding_window_t, &semian_simple_sliding_window_type, res);
  return obj;
}

VALUE
semian_simple_sliding_window_initialize(VALUE self, VALUE name, VALUE max_size)
{
  semian_simple_sliding_window_t *res = get_object(self);
  res->key = generate_key(to_s(name));

  dprintf("Initializing simple sliding window '%s' (key: %lu)", to_s(name), res->key);
  res->sem_id = initialize_single_semaphore(res->key, SEM_DEFAULT_PERMISSIONS);
  res->shmem = get_or_create_shared_memory(res->key, init_fn);

  int max_size_val = check_max_size_arg(max_size);

  sem_meta_lock(res->sem_id);
  {
    if (res->shmem->max_size == 0) {
      dprintf("Setting max_size for '%s' to %d", to_s(name), max_size_val);
      res->shmem->max_size = max_size_val;
    } else if (res->shmem->max_size != max_size_val) {
      // TODO(michaelkipper): Figure out what do do in this case...
      printf("Warning: Max size of %d is different than current value of %d", max_size_val, res->shmem->max_size);
      // dprintf("max_size %d is different than %d", max_size_val, res->shmem->max_size);
      // sem_meta_unlock(res->sem_id);
      // rb_raise(rb_eArgError, "max_size was different");
    }
  }
  sem_meta_unlock(res->sem_id);

  return self;
}

VALUE
semian_simple_sliding_window_size(VALUE self)
{
  semian_simple_sliding_window_t *res = get_object(self);
  VALUE retval;

  sem_meta_lock(res->sem_id);
  {
    retval = RB_INT2NUM(res->shmem->length);
  }
  sem_meta_unlock(res->sem_id);

  return retval;
}

VALUE
semian_simple_sliding_window_max_size(VALUE self)
{
  semian_simple_sliding_window_t *res = get_object(self);
  VALUE retval;

  sem_meta_lock(res->sem_id);
  {
    retval = RB_INT2NUM(res->shmem->max_size);
  }
  sem_meta_unlock(res->sem_id);

  return retval;
}

VALUE
semian_simple_sliding_window_values(VALUE self)
{
  semian_simple_sliding_window_t *res = get_object(self);
  VALUE retval;

  sem_meta_lock(res->sem_id);
  {
    retval = rb_ary_new_capa(res->shmem->length);
    for (int i = 0; i < res->shmem->length; ++i) {
      int index = (res->shmem->start + i) % res->shmem->max_size;
      int value = res->shmem->data[index];
      rb_ary_store(retval, i, RB_INT2NUM(value));
    }
  }
  sem_meta_unlock(res->sem_id);

  return retval;
}

VALUE
semian_simple_sliding_window_last(VALUE self)
{
  semian_simple_sliding_window_t *res = get_object(self);
  VALUE retval;

  sem_meta_lock(res->sem_id);
  {
    int index = (res->shmem->start + res->shmem->length - 1) % res->shmem->max_size;
    retval = RB_INT2NUM(res->shmem->data[index]);
  }
  sem_meta_unlock(res->sem_id);

  return retval;
}

VALUE
semian_simple_sliding_window_clear(VALUE self)
{
  semian_simple_sliding_window_t *res = get_object(self);

  sem_meta_lock(res->sem_id);
  {
    res->shmem->length = 0;
    res->shmem->start = 0;
    res->shmem->end = 0;
  }
  sem_meta_unlock(res->sem_id);

  return self;
}

VALUE
semian_simple_sliding_window_reject(VALUE self)
{
  semian_simple_sliding_window_t *res = get_object(self);

  rb_need_block();

  sem_meta_lock(res->sem_id);
  {
    // Store these values because we're going to be modifying the buffer.
    int start = res->shmem->start;
    int length = res->shmem->length;

    int cleared = 0;
    for (int i = 0; i < length; ++i) {
      int index = (start + i) % length;
      int value = res->shmem->data[index];
      VALUE y = rb_yield(RB_INT2NUM(value));
      if (RTEST(y)) {
        if (cleared++ != i) {
          sem_meta_unlock(res->sem_id);
          rb_raise(rb_eArgError, "reject! must delete monotonically");
        }
        res->shmem->start = (res->shmem->start + 1) % res->shmem->length;
        res->shmem->length--;
      }
    }
  }
  sem_meta_unlock(res->sem_id);

  return self;
}

VALUE
semian_simple_sliding_window_push(VALUE self, VALUE value)
{
  semian_simple_sliding_window_t *res = get_object(self);

  sem_meta_lock(res->sem_id);
  {
    if (res->shmem->length == res->shmem->max_size) {
      res->shmem->length--;
      res->shmem->start = (res->shmem->start + 1) % res->shmem->max_size;
    }

    const int index = res->shmem->end;
    res->shmem->length++;
    res->shmem->data[index] = RB_NUM2INT(value);
    res->shmem->end = (res->shmem->end + 1) % res->shmem->max_size;
  }
  sem_meta_unlock(res->sem_id);

  return self;
}
