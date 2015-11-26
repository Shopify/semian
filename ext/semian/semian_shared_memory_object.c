#include "semian_shared_memory_object.h"

const int kSHMSemaphoreCount = 1; // semaphores to be acquired
const int kSHMTicketMax = 1;
const int kSHMInitializeWaitTimeout = 5; /* seconds */
const int kSHMIndexTicketLock = 0;
const int kSHMInternalTimeout = 5; /* seconds */
const int kSHMRestoreLockStateRetryCount = 5; // perform semtimedop 5 times max

static struct sembuf decrement; // = { kSHMIndexTicketLock, -1, SEM_UNDO};
static struct sembuf increment; // = { kSHMIndexTicketLock, 1, SEM_UNDO};

/*
 * Functions that handle type and memory
*/
static void semian_shm_object_mark(void *ptr);
static void semian_shm_object_free(void *ptr);
static size_t semian_shm_object_memsize(const void *ptr);

const rb_data_type_t
semian_shm_object_type = {
  "semian_shm_object",
  {
    semian_shm_object_mark,
    semian_shm_object_free,
    semian_shm_object_memsize
  },
  NULL, NULL, RUBY_TYPED_FREE_IMMEDIATELY
};

static void
semian_shm_object_mark(void *ptr)
{
  /* noop */
}
static void
semian_shm_object_free(void *ptr)
{
  semian_shm_object *data = (semian_shm_object *)ptr;
  // Under normal circumstances, memory use should be in the order of bytes, and shouldn't
  // increase if the same key/id is used, so there is no need to delete the shared memory
  // (also raises a concurrency-related bug: "object allocation during garbage collection phase")
  xfree(data);
}
static size_t
semian_shm_object_memsize(const void *ptr)
{
  return sizeof(semian_shm_object);
}
static VALUE
semian_shm_object_alloc(VALUE klass)
{
  VALUE obj;
  semian_shm_object *ptr;
  obj = TypedData_Make_Struct(klass, semian_shm_object, &semian_shm_object_type, ptr);
  return obj;
}

/*
 * Implementations
 */

VALUE
semian_shm_object_replace_alloc(VALUE klass, VALUE target)
{
  rb_define_alloc_func(target, semian_shm_object_alloc);
  return target;
}

VALUE
semian_shm_object_acquire(VALUE self, VALUE name, VALUE data_layout, VALUE permissions)
{
  semian_shm_object *ptr;
  TypedData_Get_Struct(self, semian_shm_object, &semian_shm_object_type, ptr);

  if (TYPE(name) != T_SYMBOL && TYPE(name) != T_STRING)
    rb_raise(rb_eTypeError, "id must be a symbol or string");
  if (TYPE(data_layout) != T_ARRAY)
    rb_raise(rb_eTypeError, "expected array for data_layout");
  if (TYPE(permissions) != T_FIXNUM)
    rb_raise(rb_eTypeError, "expected integer for permissions");

  int byte_size = 0;
  for (int i = 0; i < RARRAY_LEN(data_layout); ++i) {
    VALUE type_symbol = RARRAY_PTR(data_layout)[i];
    if (TYPE(type_symbol) != T_SYMBOL)
      rb_raise(rb_eTypeError, "id must be a symbol or string");

    if (rb_intern("int") == SYM2ID(type_symbol))
      byte_size += sizeof(int);
    else if (rb_intern("long") == SYM2ID(type_symbol))
      byte_size += sizeof(long);
    // Can definitely add more
    else
      rb_raise(rb_eTypeError, "%s is not a valid C type", rb_id2name(SYM2ID(type_symbol)));
  }

  if (byte_size <= 0)
    rb_raise(rb_eArgError, "total size must be larger than 0");

  const char *id_str = NULL;
  if (TYPE(name) == T_SYMBOL) {
    id_str = rb_id2name(rb_to_id(name));
  } else if (TYPE(name) == T_STRING) {
    id_str = RSTRING_PTR(name);
  }
  ptr->key = generate_key(id_str);
  ptr->byte_size = byte_size; // byte_size >=1 or error would have been raised earlier
  ptr->semid = -1; // id's default to -1
  ptr->shmid = -1;
  ptr->shm_address = 0; // address defaults to NULL
  ptr->lock_count = 0; // Emulates recursive mutex, 0->1 locks, 1->0 unlocks, rest noops
  ptr->permissions = FIX2LONG(permissions);
  ptr->initialize_memory = NULL;

  // Concrete classes must implement this in a subclass in C to bind a callback function of type
  // void (*initialize_memory)(size_t byte_size, void *dest, void *prev_data, size_t prev_data_byte_size);
  // to location ptr->initialize_memory, where ptr is a semian_shm_object*
  // It is called when memory needs to be initialized or resized, possibly using previous memory
  rb_funcall(self, rb_intern("bind_initialize_memory_callback"), 0);
  if (NULL == ptr->initialize_memory)
    rb_raise(rb_eNotImpError, "callback was not bound to ptr->initialize_memory");
  semian_shm_object_acquire_semaphore(self);
  semian_shm_object_synchronize(self);

  return Qtrue;
}

VALUE
semian_shm_object_destroy(VALUE self)
{
  VALUE result = semian_shm_object_cleanup_memory(self);
  if (!result)
    return Qfalse;
  result = semian_shm_object_delete_semaphore(self);
  return result;
}

/*
 * Create or acquire previously made semaphore
 */

static int
create_semaphore_and_initialize_and_set_permissions(int key, int permissions)
{
  int semid = 0;
  int flags = 0;

  flags = IPC_EXCL | IPC_CREAT | permissions;

  semid = semget(key, kSHMSemaphoreCount, flags);
  if (semid >= 0) {
    if (-1 == semctl(semid, 0, SETVAL, kSHMTicketMax)) {
      rb_warn("semctl: failed to set semaphore with semid %d, position 0 to %d", semid, 1);
      raise_semian_syscall_error("semctl()", errno);
    }
  } else if (semid == -1 && errno == EEXIST) {
    flags &= ~IPC_EXCL;
    semid = semget(key, kSHMSemaphoreCount, flags);
  }

  if (-1 != semid){
    set_semaphore_permissions(semid, permissions); // Borrowed from semian.c
  }

  return semid;
}


VALUE
semian_shm_object_acquire_semaphore (VALUE self)
{
  semian_shm_object *ptr;
  TypedData_Get_Struct(self, semian_shm_object, &semian_shm_object_type, ptr);

  if (-1 == (ptr->semid = create_semaphore_and_initialize_and_set_permissions(ptr->key, ptr->permissions))) {
    raise_semian_syscall_error("semget()", errno);
  }
  return self;
}

VALUE
semian_shm_object_delete_semaphore(VALUE self)
{
  semian_shm_object *ptr;
  TypedData_Get_Struct(self, semian_shm_object, &semian_shm_object_type, ptr);
  if (-1 == ptr->semid){ // do nothing if semaphore not acquired
    return Qfalse;
  }
  if (-1 == semctl(ptr->semid, 0, IPC_RMID)) {
    if (EIDRM == errno) {
      rb_warn("semctl: failed to delete semaphore set with semid %d: already removed", ptr->semid);
      raise_semian_syscall_error("semctl()", errno);
      ptr->semid = -1;
    } else {
      rb_warn("semctl: failed to remove semaphore with semid %d, errno %d (%s)", ptr->semid, errno, strerror(errno));
      raise_semian_syscall_error("semctl()", errno);
    }
  } else {
    ptr->semid = -1;
  }
  return self;
}

/*
 * lock & unlock functions, should be called like
 * (VALUE) WITHOUT_GVL(semian_shm_object_unlock_without_gvl, (void *)ptr, RUBY_UBF_IO, NULL)
 */

static void *
semian_shm_object_lock_without_gvl(void *v_ptr)
{
  semian_shm_object *ptr = v_ptr;
  if (-1 == ptr->semid) {
    rb_raise(eInternal, "semid not set, errno %d: (%s)", errno, strerror(errno));
  }
  struct timespec ts = { 0 };
  ts.tv_sec = kSHMInternalTimeout;
  if (0 != ptr->lock_count || -1 != semtimedop(ptr->semid, &decrement, 1, &ts)) {
    ptr->lock_count += 1;
  } else {
    rb_raise(eInternal, "error acquiring semaphore lock to mutate circuit breaker structure, %d: (%s)", errno, strerror(errno));
  }
  return (void *)Qtrue;
}

static void *
semian_shm_object_unlock_without_gvl(void *v_ptr)
{
  semian_shm_object *ptr = v_ptr;
  if (-1 == ptr->semid){
    rb_raise(eInternal, "semid not set, errno %d: (%s)", errno, strerror(errno));
  }
  if (1 != ptr->lock_count || -1 != semop(ptr->semid, &increment, 1)) { // No need for semtimedop
    ptr->lock_count -= 1;
  } else {
    rb_raise(eInternal, "error unlocking semaphore, %d (%s)", errno, strerror(errno));
  }
  return (void *)Qtrue;
}

/*
 *  Wrap the lock-unlock functionality in ensures
 */

typedef struct { // Workaround rb_ensure only allows one argument for each callback function
  int pre_block_lock_count_state;
  semian_shm_object *ptr;
} lock_status;

static VALUE
semian_shm_object_synchronize_with_block(VALUE self)
{
  semian_shm_object_synchronize_memory_and_size(self, Qfalse);
  if (!rb_block_given_p())
    return Qnil;
  return rb_yield(Qnil);
}

static VALUE
semian_shm_object_synchronize_restore_lock_status(VALUE v_status)
{
  lock_status *status = (lock_status *) v_status;
  int tries = 0;
  while (++tries < kSHMRestoreLockStateRetryCount && status->ptr->lock_count > status->pre_block_lock_count_state)
    return (VALUE) WITHOUT_GVL(semian_shm_object_unlock_without_gvl, (void *)(status->ptr), RUBY_UBF_IO, NULL);
  if (tries >= kSHMRestoreLockStateRetryCount)
    rb_raise(eSyscall, "Failed to restore lock status after %d tries", kSHMRestoreLockStateRetryCount);
  tries = 0;
  while (++tries < kSHMRestoreLockStateRetryCount && status->ptr->lock_count < status->pre_block_lock_count_state)
    return (VALUE) WITHOUT_GVL(semian_shm_object_lock_without_gvl, (void *)(status->ptr), RUBY_UBF_IO, NULL);
  if (tries >= kSHMRestoreLockStateRetryCount)
    rb_raise(eSyscall, "Failed to restore lock status after %d tries", kSHMRestoreLockStateRetryCount);
  return Qnil;
}

VALUE
semian_shm_object_synchronize(VALUE self) { // receives a block
  semian_shm_object *ptr;
  TypedData_Get_Struct(self, semian_shm_object, &semian_shm_object_type, ptr);
  lock_status status = { ptr->lock_count, ptr };
  WITHOUT_GVL(semian_shm_object_lock_without_gvl, (void *)ptr, RUBY_UBF_IO, NULL);
  return rb_ensure(semian_shm_object_synchronize_with_block, self, semian_shm_object_synchronize_restore_lock_status, (VALUE)&status);
}

void
define_method_with_synchronize(VALUE klass, const char *name, VALUE (*func)(ANYARGS), int argc)
{
  rb_define_method(klass, name, func, argc);
  rb_funcall(klass, rb_intern("do_with_sync"), 1, rb_str_new2(name));
}

/*
 * Memory functions
 */

VALUE
semian_shm_object_synchronize_memory_and_size(VALUE self, VALUE is_master_obj) {
  semian_shm_object *ptr;
  TypedData_Get_Struct(self, semian_shm_object, &semian_shm_object_type, ptr);

  struct shmid_ds shm_info = { };
  const int SHMMIN = 1; // minimum size of shared memory on linux
  key_t key = ptr->key;

  int is_master = RTEST(is_master_obj); // Controls whether synchronization is master or slave (both fast-forward, only master resizes/initializes)
  is_master |= (-1 == ptr->shmid) && (0 == ptr->shm_address);

  int shmid_out_of_sync = 0;
  shmid_out_of_sync |= (-1 == ptr->shmid) && (0 == ptr->shm_address); // If not attached at all
  if ((-1 != ptr->shmid) && (-1 != shmctl(ptr->shmid, IPC_STAT, &shm_info))) {
    shmid_out_of_sync |= shm_info.shm_perm.mode & SHM_DEST && // If current attached memory is marked for deletion
                         ptr->shmid != shmget(key, SHMMIN, IPC_CREAT | ptr->permissions); // If shmid not in sync
  }

  size_t requested_byte_size = ptr->byte_size;
  int first_sync = (-1 == ptr->shmid) && (shmid_out_of_sync);

  if (shmid_out_of_sync) { // We need to fast-forward to the current state and memory attachment
    semian_shm_object_cleanup_memory(self);
    if ((-1 == (ptr->shmid = shmget(key, SHMMIN, ptr->permissions)))) {
      if ((-1 == (ptr->shmid = shmget(key, ptr->byte_size, IPC_CREAT | IPC_EXCL | ptr->permissions)))) {
        rb_raise(eSyscall, "shmget failed to create or attach current memory with key %d shmid %d errno %d (%s)", key, ptr->shmid, errno, strerror(errno));
      } // If we can neither create a new memory block nor get the current one with a key, something's wrong
    }
    if ((void *)-1 == (ptr->shm_address = shmat(ptr->shmid, NULL, 0))) {
      ptr->shm_address = NULL;
      rb_raise(eSyscall, "shmat failed to mount current memory with key %d shmid %d errno %d (%s)", key, ptr->shmid, errno, strerror(errno));
    }
  }

  if (-1 == shmctl(ptr->shmid, IPC_STAT, &shm_info)){
    rb_raise(eSyscall, "shmctl failed to inspect current memory with key %d shmid %d errno %d (%s)", key, ptr->shmid, errno, strerror(errno));
  }
  ptr->byte_size = shm_info.shm_segsz;

  int old_mem_attach_count = shm_info.shm_nattch;

  if (is_master) {
    if (ptr->byte_size == requested_byte_size && first_sync && 1 == old_mem_attach_count) {
      ptr->initialize_memory(ptr->byte_size, ptr->shm_address, NULL, 0); // We clear the memory if worker is first to attach
    } else if (ptr->byte_size != requested_byte_size) {
      void *old_shm_address = ptr->shm_address;
      size_t old_byte_size = ptr->byte_size;
      unsigned char old_memory_content[old_byte_size]; // It is unsafe to use malloc here to store a copy of the memory
      memcpy(old_memory_content, old_shm_address, old_byte_size);
      semian_shm_object_cleanup_memory(self); // This may fail

      if (-1 == (ptr->shmid = shmget(key, requested_byte_size, IPC_CREAT | IPC_EXCL | ptr->permissions))) {
        rb_raise(eSyscall, "shmget failed to create new resized memory with key %d shmid %d errno %d (%s)", key, ptr->shmid, errno, strerror(errno));
      }
      if ((void *)-1 == (ptr->shm_address = shmat(ptr->shmid, NULL, 0))) {
        rb_raise(eSyscall, "shmat failed to mount new resized memory with key %d shmid %d errno %d (%s)", key, ptr->shmid, errno, strerror(errno));
      }
      ptr->byte_size = requested_byte_size;

      ptr->initialize_memory(ptr->byte_size, ptr->shm_address, old_memory_content, old_byte_size);
    }
  }
  return self;
}

static VALUE
semian_shm_object_cleanup_memory_inner(VALUE self)
{
  semian_shm_object *ptr;
  TypedData_Get_Struct(self, semian_shm_object, &semian_shm_object_type, ptr);

  if (0 != ptr->shm_address && -1 == shmdt(ptr->shm_address)) {
    rb_raise(eSyscall,"shmdt: no attached memory at %p, errno %d (%s)", ptr->shm_address, errno, strerror(errno));
  }
  ptr->shm_address = 0;

  if (-1 != ptr->shmid && -1 == shmctl(ptr->shmid, IPC_RMID, 0)) {
    if (errno != EINVAL)
      rb_raise(eSyscall,"shmctl: error flagging memory for removal with shmid %d, errno %d (%s)", ptr->shmid, errno, strerror(errno));
  }
  ptr->shmid = -1;
  return Qnil;
}

VALUE
semian_shm_object_cleanup_memory(VALUE self)
{
  semian_shm_object *ptr;
  TypedData_Get_Struct(self, semian_shm_object, &semian_shm_object_type, ptr);
  lock_status status = { ptr->lock_count, ptr };
  WITHOUT_GVL(semian_shm_object_lock_without_gvl, (void *)ptr, RUBY_UBF_IO, NULL);
  return rb_ensure(semian_shm_object_cleanup_memory_inner, self, semian_shm_object_synchronize_restore_lock_status, (VALUE)&status);
}

static VALUE
semian_shm_object_semid(VALUE self)
{
  semian_shm_object *ptr;
  TypedData_Get_Struct(self, semian_shm_object, &semian_shm_object_type, ptr);
  if (-1 == ptr->semid)
    return -1;
  semian_shm_object_synchronize(self);
  return INT2NUM(ptr->semid);
}
static VALUE
semian_shm_object_shmid(VALUE self)
{
  semian_shm_object *ptr;
  TypedData_Get_Struct(self, semian_shm_object, &semian_shm_object_type, ptr);
  return INT2NUM(ptr->shmid);
}

void
Init_semian_shm_object (void) {

  VALUE cSemianModule = rb_const_get(rb_cObject, rb_intern("Semian"));
  VALUE cSysVSharedMemory = rb_const_get(cSemianModule, rb_intern("SysVSharedMemory"));

  rb_define_method(cSysVSharedMemory, "acquire_memory_object", semian_shm_object_acquire, 3);
  rb_define_method(cSysVSharedMemory, "destroy", semian_shm_object_destroy, 0);
  rb_define_method(cSysVSharedMemory, "synchronize", semian_shm_object_synchronize, 0);

  rb_define_method(cSysVSharedMemory, "semid", semian_shm_object_semid, 0);
  define_method_with_synchronize(cSysVSharedMemory, "shmid", semian_shm_object_shmid, 0);

  rb_define_singleton_method(cSysVSharedMemory, "replace_alloc", semian_shm_object_replace_alloc, 1);

  decrement.sem_num = kSHMIndexTicketLock;
  decrement.sem_op = -1;
  decrement.sem_flg = SEM_UNDO;

  increment.sem_num = kSHMIndexTicketLock;
  increment.sem_op = 1;
  increment.sem_flg = SEM_UNDO;

  Init_semian_integer();
  Init_semian_sliding_window();
}
