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

static int
check_max_size_arg(VALUE max_size)
{
  int retval = -1;
  switch (rb_type(max_size)) {
  case T_NIL:
  case T_UNDEF:
    retval = SLIDING_WINDOW_MAX_SIZE; break;
  case T_FLOAT:
    rb_warn("semian sliding window max_size is a float, converting to fixnum");
    retval = (int)(RFLOAT_VALUE(max_size)); break;
  case T_FIXNUM:
  case T_BIGNUM:
    retval = RB_NUM2INT(max_size); break;
  default:
    rb_raise(rb_eArgError, "unknown type for max_size: %d", TYPE(max_size));
  }

  if (retval <= 0) {
    rb_raise(rb_eArgError, "max_size must be greater than zero");
  } else if (retval > SLIDING_WINDOW_MAX_SIZE) {
    rb_raise(rb_eArgError, "max_size cannot be greater than %d", SLIDING_WINDOW_MAX_SIZE);
  }

  return retval;
}

static float
check_scale_factor_arg(VALUE scale_factor)
{
  float retval = 1.0;
  switch(rb_type(scale_factor)) {
  case T_NIL:
  case T_UNDEF:
    retval = 1.0; break;
  case T_FLOAT:
    retval = rb_float_value(scale_factor); break;
  case T_FIXNUM:
  case T_BIGNUM:
    rb_warn("semian sliding window scale_factor is an int, converting to float");
    retval = (float)RB_NUM2INT(scale_factor); break;
  default:
    rb_raise(rb_eArgError, "unknown type for scale_factor: %d", TYPE(scale_factor));
  }

  if (retval <= 0.0) {
    rb_raise(rb_eArgError, "scale_factor must be greater than zero");
  } else if (retval > 1.0) {
    rb_raise(rb_eArgError, "scale_factor cannot be greater than 1.0");
  }

  return retval;
}

static VALUE
grow_window(int sem_id, semian_simple_sliding_window_shared_t* window, int new_max_size)
{
  if (new_max_size > SLIDING_WINDOW_MAX_SIZE) {
    sem_meta_unlock(sem_id);
    rb_raise(rb_eArgError, "Cannot grow window to %d (MAX_SIZE=%d)", new_max_size, SLIDING_WINDOW_MAX_SIZE);
  }

  int end = window->max_size ? (window->start + window->length) % window->max_size : 0;
  dprintf("Growing window - sem_id:%d start:%d end:%d length:%d max_size:%d new_max_size:%d", sem_id, window->start, end, window->length, window->max_size, new_max_size);

  if (window->length == 0) {
    window->start = 0;
  } else if (end > window->start) {
    // Easy case - the window doesn't wrap around
  } else {
    // Hard case - the window wraps, and data might need to move
    int offset = new_max_size - window->max_size;
    for (int i = offset - window->start - 1; i >= 0; --i) {
      int srci = window->start + i;
      int dsti = window->start + offset + i;
      window->data[dsti] = window->data[srci];
    }
    window->start += offset;
  }

  window->max_size = new_max_size;

  return RB_INT2NUM(new_max_size);
}

static void swap(int *a, int *b) {
  int c = *a;
  *a = *b;
  *b = c;
}

static VALUE
shrink_window(int sem_id, semian_simple_sliding_window_shared_t* window, int new_max_size)
{
  if (new_max_size > SLIDING_WINDOW_MAX_SIZE) {
    sem_meta_unlock(sem_id);
    rb_raise(rb_eArgError, "Cannot shrink window to %d (MAX_SIZE=%d)", new_max_size, SLIDING_WINDOW_MAX_SIZE);
  }

  int new_length = (new_max_size > window->length) ? window->length : new_max_size;

  int end = window->max_size ? (window->start + window->length) % window->max_size : 0;
  dprintf("Shrinking window - sem_id:%d start:%d end:%d length:%d max_size:%d new_max_size:%d", sem_id, window->start, end, window->length, window->max_size, new_max_size);

  if (window->length == 0) {
    window->start = 0;
  } else if (end > window->start) {
    // Easy case - the window doesn't wrap around
    window->start = window->start + new_length;
  } else {
    // Hard case - the window wraps, so re-index the data
    // Adapted from http://www.cplusplus.com/reference/algorithm/rotate/
    int first = 0;
    int middle = (end - new_max_size + window->max_size) % window->max_size;
    int last = window->max_size;
    int next = middle;
    while (first != next) {
      swap(&window->data[first++], &window->data[next++]);
      if (next == last) {
        next = middle;
      } else if (first == middle) {
        middle = next;
      }
    }
    window->start = 0;
  }

  window->max_size = new_max_size;
  window->length = new_length;

  return RB_INT2NUM(new_max_size);
}

static VALUE
resize_window(int sem_id, semian_simple_sliding_window_shared_t* window, int new_max_size)
{
  if (new_max_size > SLIDING_WINDOW_MAX_SIZE) return Qnil;

  if (window->max_size < new_max_size) {
    return grow_window(sem_id, window, new_max_size);
  } else if (window->max_size > new_max_size) {
    return shrink_window(sem_id, window, new_max_size);
  }

  return Qnil;
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
  rb_define_method(cSlidingWindow, "initialize_sliding_window", semian_simple_sliding_window_initialize, 3);
  rb_define_method(cSlidingWindow, "size", semian_simple_sliding_window_size, 0);
  rb_define_method(cSlidingWindow, "length", semian_simple_sliding_window_size, 0); // Alias
  rb_define_method(cSlidingWindow, "resize_to", semian_simple_sliding_window_resize_to, 1);
  rb_define_method(cSlidingWindow, "max_size", semian_simple_sliding_window_max_size_get, 0);
  rb_define_method(cSlidingWindow, "max_size=", semian_simple_sliding_window_max_size_set, 1);
  rb_define_method(cSlidingWindow, "values", semian_simple_sliding_window_values, 0);
  rb_define_method(cSlidingWindow, "last", semian_simple_sliding_window_last, 0);
  rb_define_method(cSlidingWindow, "push", semian_simple_sliding_window_push, 1);
  rb_define_method(cSlidingWindow, "<<", semian_simple_sliding_window_push, 1); // Alias
  rb_define_method(cSlidingWindow, "clear", semian_simple_sliding_window_clear, 0);
  rb_define_method(cSlidingWindow, "destroy", semian_simple_sliding_window_clear, 0);  // Alias
  rb_define_method(cSlidingWindow, "reject!", semian_simple_sliding_window_reject, 0);
}

VALUE
semian_simple_sliding_window_alloc(VALUE klass)
{
  semian_simple_sliding_window_t *res;
  VALUE obj = TypedData_Make_Struct(klass, semian_simple_sliding_window_t, &semian_simple_sliding_window_type, res);
  return obj;
}

static int
get_number_of_registered_workers(semian_simple_sliding_window_t* res)
{
  int sem_id = semget(res->parent_key, SI_NUM_SEMAPHORES, SEM_DEFAULT_PERMISSIONS);
  if (sem_id == -1) {
    dprintf("Warning: Could not get semaphore for key=%lu", res->parent_key);
    return 1;
  }

  int retval = semctl(sem_id, SI_SEM_REGISTERED_WORKERS, GETVAL);
  if (retval == -1) {
    dprintf("Warning: Could not get SI_SEM_REGISTERED_WORKERS for sem_id=%d", sem_id);
    return 1;
  }

  return retval;
}

static int max(int a, int b) {
  return a > b ? a : b;
}

VALUE
semian_simple_sliding_window_initialize(VALUE self, VALUE name, VALUE max_size, VALUE scale_factor)
{
  semian_simple_sliding_window_t *res = get_object(self);

  char buffer[1024];
  strcpy(buffer, to_s(name));
  strcat(buffer, "_sliding_window");
  res->key = generate_key(buffer);

  // Store the parent key, not the parent sem_id, since it might not exist yet.
  res->parent_key = generate_key(to_s(name));

  dprintf("Initializing simple sliding window '%s' (key: %lu)", buffer, res->key);
  res->sem_id = initialize_single_semaphore(res->key, SEM_DEFAULT_PERMISSIONS, 1);
  res->shmem = get_or_create_shared_memory(res->key);
  res->error_threshold = check_max_size_arg(max_size);
  res->scale_factor = check_scale_factor_arg(scale_factor);

  sem_meta_lock(res->sem_id);
  {
    int workers = get_number_of_registered_workers(res);
    float scale = (workers > 1) ? res->scale_factor : 1.0; // TODO: Parameterize
    int error_threshold = max(res->error_threshold, (int) ceil(workers * scale * res->error_threshold));

    dprintf("  workers:%d scale:%0.2f error_threshold:%d", workers, scale, error_threshold);
    resize_window(res->sem_id, res->shmem, error_threshold);
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
semian_simple_sliding_window_resize_to(VALUE self, VALUE new_size)
{
  semian_simple_sliding_window_t *res = get_object(self);
  VALUE retval = Qnil;

  int new_max_size = RB_NUM2INT(new_size);
  if (new_max_size < 1) {
    rb_raise(rb_eArgError, "cannot resize to %d", new_max_size);
  }

  sem_meta_lock(res->sem_id);
  {
    retval = resize_window(res->sem_id, res->shmem, new_max_size);
  }
  sem_meta_unlock(res->sem_id);

  return retval;
}

VALUE
semian_simple_sliding_window_max_size_get(VALUE self)
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
semian_simple_sliding_window_max_size_set(VALUE self, VALUE new_size)
{
  semian_simple_sliding_window_t *res = get_object(self);
  VALUE retval;

  int new_max_size = RB_NUM2INT(new_size);
  if (new_max_size < 1) {
    rb_raise(rb_eArgError, "max_size must be positive");
  }

  sem_meta_lock(res->sem_id);
  {
    retval = resize_window(res->sem_id, res->shmem, new_max_size);
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
    dprintf("Clearing sliding window");
    res->shmem->length = 0;
    res->shmem->start = 0;
  }
  sem_meta_unlock(res->sem_id);

  return self;
}

#if 0
// Handy for debugging the sliding window, but too noisy for regular debugging.
static void dprint_window(semian_simple_sliding_window_shared_t *window)
{
  dprintf("---");
  for (int i = 0; i < window->length; ++i) {
    const int index = (window->start + i) % window->max_size;
    dprintf("  %0d: data[%d] = %d", i, index, window->data[index]);
  }
  dprintf("---");
}
#endif

VALUE
semian_simple_sliding_window_reject(VALUE self)
{
  semian_simple_sliding_window_t *res = get_object(self);

  rb_need_block();

  sem_meta_lock(res->sem_id);
  {
    semian_simple_sliding_window_shared_t *window = res->shmem;
    const int start = window->start;
    const int length = window->length;
    const int max_size = window->max_size;

    if (max_size && length) {
      int wptr = (start + length + max_size - 1) % max_size;

      // Walk the sliding window backward, from the last element to the first,
      // pushing the entries to the back of the ring. When we've gone through
      // every element, set the start pointer to the new location.
      //
      // Example, deleting "2":
      //        S       E               S     E
      //   [x,x,0,1,2,3,x,x] --> [x,x,x,0,1,3,x,x]
      //    0 1 2 3 4 5 6 7       0 1 2 3 4 5 6 7
      //
      // The runtime of this algorithm is theta(n), but n tends to be small.
      //
      dprintf("Before reject! start:%d length:%d max_size:%d", window->start, window->length, window->max_size);
      for (int i = 0; i < length; ++i) {
        const int rptr = (start + length + max_size - i - 1) % max_size;

        const int value = window->data[rptr];
        if (RTEST(rb_yield(RB_INT2NUM(value)))) {
          window->length--;
        } else {
          window->data[wptr] = value;
          wptr = (wptr + max_size - 1) % max_size;
        }
      }

      window->start = (wptr + 1) % max_size;
      dprintf("After reject! start:%d length:%d max_size:%d", window->start, window->length, window->max_size);
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
    dprintf("Before: start:%d length:%d max_size:%d", res->shmem->start, res->shmem->length, res->shmem->max_size);
    // If the window is full, make room by popping off the front.
    if (res->shmem->length == res->shmem->max_size) {
      res->shmem->length--;
      res->shmem->start = (res->shmem->start + 1) % res->shmem->max_size;
    }

    // Push onto the back of the window.
    int index = (res->shmem->start + res->shmem->length) % res->shmem->max_size;
    res->shmem->length++;
    res->shmem->data[index] = RB_NUM2INT(value);
    dprintf("Pushed %d onto data[%d] (length %d)", RB_NUM2INT(value), index, res->shmem->length);
  }
  sem_meta_unlock(res->sem_id);

  return self;
}
