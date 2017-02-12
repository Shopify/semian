#include "semian.h"

typedef struct {
  //semaphore, shared memory data and pointer
  key_t key;
  size_t byte_size;
  int lock_count; // lock only done from 0 -> 1, unlock only done from 1 -> 0, so we can 'lock' multiple times (such as in nesting functions) without actually locking
  int permissions;
  int semid;
  int shmid;
  void (*initialize_memory)(size_t byte_size, void *dest, void *prev_data, size_t prev_data_byte_size);
  void *shm_address;
} semian_shm_object;

extern const rb_data_type_t
semian_shm_object_type;

/*
 * Headers
 */

VALUE semian_shm_object_replace_alloc(VALUE klass, VALUE target);

VALUE semian_shm_object_acquire(VALUE self, VALUE id, VALUE byte_size, VALUE permissions);
VALUE semian_shm_object_destroy(VALUE self);
VALUE semian_shm_object_acquire_semaphore (VALUE self);
VALUE semian_shm_object_delete_semaphore(VALUE self);
VALUE semian_shm_object_cleanup_memory (VALUE self);
VALUE semian_shm_object_synchronize_memory_and_size (VALUE self, VALUE is_master);

VALUE semian_shm_object_synchronize(VALUE self);
void define_method_with_synchronize(VALUE klass, const char *name, VALUE (*func)(ANYARGS), int argc);

void Init_semian_integer (void);
