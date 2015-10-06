#include "semian_shared_memory_object.h"

const int kSHMSemaphoreCount = 1; // # semaphores to be acquired
const int kSHMTicketMax = 1;
const int kSHMInitializeWaitTimeout = 5; /* seconds */
const int kSHMIndexTicketLock = 0;
const int kSHMInternalTimeout = 5; /* seconds */

static struct sembuf decrement; // = { kSHMIndexTicketLock, -1, SEM_UNDO};
static struct sembuf increment; // = { kSHMIndexTicketLock, 1, SEM_UNDO};

/*
 * Functions that handle type and memory
*/
static void semian_shm_object_mark(void *ptr);
static void semian_shm_object_free(void *ptr);
static size_t semian_shm_object_memsize(const void *ptr);

static void *semian_shm_object_lock_without_gvl(void *v_ptr);
static void *semian_shm_object_unlock_without_gvl(void *v_ptr);

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
  semian_shm_object *data = (semian_shm_object *) ptr;
  // Under normal circumstances, memory use should be in the order of bytes,
  //   and shouldn't increase if the same key/id is used
  //   so there is no need to call this unless certain all other semian processes are stopped
  //   (also raises concurrency errors: "object allocation during garbage collection phase")

  xfree(data);
}
static size_t
semian_shm_object_memsize(const void *ptr)
{
  return

  sizeof(semian_shm_object);
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
semian_shm_object_is_shared(VALUE klass)
{
  return Qtrue;
}

VALUE
semian_shm_object_sizeof(VALUE klass, VALUE type)
{
  if (TYPE(type) != T_SYMBOL){
    rb_raise(rb_eTypeError, "id must be a symbol or string");
  }

  if (rb_intern("int") == SYM2ID(type))
    return INT2NUM(sizeof(int));
  else if (rb_intern("long") == SYM2ID(type))
    return INT2NUM(sizeof(long));
  else
    return INT2NUM(0);
}


VALUE
semian_shm_object_acquire(VALUE self, VALUE name, VALUE byte_size, VALUE permissions)
{
  semian_shm_object *ptr;
  TypedData_Get_Struct(self, semian_shm_object, &semian_shm_object_type, ptr);

  if (TYPE(name) != T_SYMBOL && TYPE(name) != T_STRING)
    rb_raise(rb_eTypeError, "id must be a symbol or string");
  if (TYPE(byte_size) != T_FIXNUM)
    rb_raise(rb_eTypeError, "expected integer for byte_size");
  if (TYPE(permissions) != T_FIXNUM)
    rb_raise(rb_eTypeError, "expected integer for permissions");

  if (NUM2SIZET(byte_size) <= 0)
    rb_raise(rb_eArgError, "byte_size must be larger than 0");

  const char *id_str = NULL;
  if (TYPE(name) == T_SYMBOL) {
    id_str = rb_id2name(rb_to_id(name));
  } else if (TYPE(name) == T_STRING) {
    id_str = RSTRING_PTR(name);
  }
  ptr->key = generate_key(id_str);

  // Guarantee byte_size >=1 or error thrown
  ptr->byte_size = NUM2SIZET(byte_size);

  // id's default to -1
  ptr->semid = -1;
  ptr->shmid = -1;
  // addresses default to NULL
  ptr->shm_address = 0;
  ptr->lock_triggered = 0;
  ptr->permissions = FIX2LONG(permissions);

  // Will throw NotImplementedError if not defined in concrete subclasses
  // Implement bind_init_fn as a function with type
  // static VALUE bind_init_fn(VALUE self)
  // that binds ptr->object_init_fn to an init function called after memory is made
  rb_funcall(self, rb_intern("bind_init_fn"), 0);

  semian_shm_object_acquire_semaphore(self, permissions);
  semian_shm_object_acquire_memory(self, permissions, Qtrue);

  return self;
}

VALUE
semian_shm_object_destroy(VALUE self)
{
  VALUE result = semian_shm_object_delete_memory(self);
  if (!result)
    return Qfalse;
  result = semian_shm_object_delete_semaphore(self);
  return result;
}


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
    set_semaphore_permissions(semid, permissions);
  }

  return semid;
}


/*
 * Create or acquire previously made semaphore
 */

VALUE
semian_shm_object_acquire_semaphore (VALUE self, VALUE permissions)
{
  // Function flow, semaphore creation methods are
  //   borrowed from semian.c since they have been previously tested

  semian_shm_object *ptr;
  TypedData_Get_Struct(self, semian_shm_object, &semian_shm_object_type, ptr);

  if (TYPE(permissions) != T_FIXNUM)
    rb_raise(rb_eTypeError, "expected integer for permissions");

  key_t key = ptr->key;
  int semid = create_semaphore_and_initialize_and_set_permissions(key, FIX2LONG(permissions));
  if (-1 == semid) {
    raise_semian_syscall_error("semget()", errno);
  }
  ptr->semid = semid;

  return self;
}

VALUE
semian_shm_object_delete_semaphore(VALUE self)
{
  semian_shm_object *ptr;
  TypedData_Get_Struct(self, semian_shm_object, &semian_shm_object_type, ptr);
  if (-1 == ptr->semid) // do nothing if semaphore not acquired
    return Qfalse;

  if (-1 == semctl(ptr->semid, 0, IPC_RMID)) {
    if (EIDRM == errno) {
      rb_warn("semctl: failed to delete semaphore set with semid %d: already removed", ptr->semid);
      raise_semian_syscall_error("semctl()", errno);
      ptr->semid = -1;
    } else {
      rb_warn("semctl: failed to remove semaphore with semid %d, errno %d (%s)",ptr->semid, errno, strerror(errno));
      raise_semian_syscall_error("semctl()", errno);
    }
  } else {
    ptr->semid = -1;
  }
  return self;
}

/*
 * semian_shm_object_lock/unlock and associated functions decrement/increment semaphore
 */

static void *
semian_shm_object_lock_without_gvl(void *v_ptr)
{
  semian_shm_object *ptr = v_ptr;
  if (-1 == ptr->semid){
    rb_raise(eInternal, "semid not set, errno %d: (%s)", errno, strerror(errno));
    return (void *)Qfalse;
  }
  VALUE retval;

  struct timespec ts = { 0 };
  ts.tv_sec = kSHMInternalTimeout;
  if (0 == ptr->lock_triggered) {
    if (-1 == semtimedop(ptr->semid,&decrement,1, &ts)) {
      rb_raise(eInternal, "error acquiring semaphore lock to mutate circuit breaker structure, %d: (%s)", errno, strerror(errno));
      retval=Qfalse;
    } else {
      (ptr->lock_triggered)+=1;
      retval=Qtrue;
    }
  } else {
    (ptr->lock_triggered)+=1;
    retval=Qtrue;
  }
  return (void *)retval;
}

VALUE
semian_shm_object_lock(VALUE self)
{
  semian_shm_object *ptr;
  TypedData_Get_Struct(self, semian_shm_object, &semian_shm_object_type, ptr);
  return (VALUE) WITHOUT_GVL(semian_shm_object_lock_without_gvl, (void *)ptr, RUBY_UBF_IO, NULL);
}

static void *
semian_shm_object_unlock_without_gvl(void *v_ptr)
{
  semian_shm_object *ptr = v_ptr;
  if (-1 == ptr->semid){
    rb_raise(eInternal, "semid not set, errno %d: (%s)", errno, strerror(errno));
    return (void *)Qfalse;
  }
  VALUE retval;

  if (1 == ptr->lock_triggered) {
    if (-1 == semop(ptr->semid,&increment,1)) {
      rb_raise(eInternal, "error unlocking semaphore, %d (%s)", errno, strerror(errno));
      retval=Qfalse;
    } else {
      --(ptr->lock_triggered);
      retval=Qtrue;
    }
  } else {
    --(ptr->lock_triggered);
    retval=Qtrue;
  }
  return (void *)retval;
}

VALUE
semian_shm_object_unlock(VALUE self)
{
  semian_shm_object *ptr;
  TypedData_Get_Struct(self, semian_shm_object, &semian_shm_object_type, ptr);
  return (VALUE) WITHOUT_GVL(semian_shm_object_unlock_without_gvl, (void *)ptr, RUBY_UBF_IO, NULL);
}

VALUE
semian_shm_object_unlock_all(VALUE self)
{
  semian_shm_object *ptr;
  TypedData_Get_Struct((VALUE)self, semian_shm_object, &semian_shm_object_type, ptr);
  while (ptr->lock_triggered > 0)
    semian_shm_object_unlock(self);
  return self;
}

static int
create_and_resize_memory(key_t key, int byte_size, long permissions, int should_keep_req_byte_size_bool,
  int *created, void **data_copy, size_t *data_copy_byte_size, int *prev_mem_attach_count, semian_shm_object *ptr, VALUE self) {

  // Below will handle acquiring/creating new memory, and possibly resizing the
  //   memory or the ptr->byte_size depending on
  //   should_keep_req_byte_size_bool

  int shmid=-1;
  int failed=0;

  int requested_byte_size = byte_size;
  int flags = IPC_CREAT | IPC_EXCL | permissions;

  int actual_byte_size = 0;

  // We fill both actual_byte_size and requested_byte_size
  // Logic matrix:
  //                                         actual=>req   | actual=req |   actual<req
  //                                    -----------------------------------------
  //  should_keep_req_byte_size_bool | no err, shrink mem  |   no err   | error, expand mem
  // !should_keep_req_byte_size_bool | no err, ++ max size |   no err   | error, -- max size

  if (-1 == (shmid = shmget( key, requested_byte_size, flags))) {
    if (errno == EEXIST) {
      if (-1 != (shmid = shmget(key, requested_byte_size, flags & ~IPC_EXCL))) {
        struct shmid_ds shm_info;
        if (-1 != shmctl(shmid, IPC_STAT, &shm_info)){
          actual_byte_size = shm_info.shm_segsz;
          *prev_mem_attach_count = shm_info.shm_nattch;
        } else
          failed = -1;
      } else {
        failed = -2;
      }
    }
    // Else, this could be any number of errors
    // 1. segment with key exists but requested size  > current mem size
    // 2. segment was requested to be created, but (size > SHMMAX || size < SHMMIN)
    // 3. Other error

    // We can only see SHMMAX and SHMMIN through console commands
    // Unlikely for 2 to occur, so we check by requesting a memory of size 1 byte
    if (-1 != (shmid = shmget(key, 1, flags & ~IPC_EXCL))) {
      struct shmid_ds shm_info;
      if (-1 != shmctl(shmid, IPC_STAT, &shm_info)){
        actual_byte_size = shm_info.shm_segsz;
        *prev_mem_attach_count = shm_info.shm_nattch;
        failed = 0;
      } else
        failed=-3;
    } else { // Error, exit
      failed=-4;
    }
  } else {
    *created = 1;
    actual_byte_size = requested_byte_size;
  }

  *data_copy_byte_size = actual_byte_size;
  if (should_keep_req_byte_size_bool && !failed) { // resizing may occur
    // we want to keep this worker's data
    // We flag old mem by IPC_RMID and copy data

    if (actual_byte_size != requested_byte_size) {
      void *data;

      if ((void *)-1 != (data = shmat(shmid, (void *)0, 0))) {

        *data_copy = malloc(actual_byte_size);
        memcpy(*data_copy,data,actual_byte_size);
        ptr->shmid=shmid;
        ptr->shm_address = data;
        semian_shm_object_delete_memory_inner(ptr, 1, self, *data_copy);

        // Flagging for deletion sets a shm's associated key to be 0 so shmget gets a different shmid.
        // If this worker is creating the new memory
        if (-1 != (shmid = shmget(key, requested_byte_size, flags))) {
          *created = 1;
        } else { // failed to get new memory, exit
          failed=-5;
        }
      } else { // failed to attach, exit
        rb_raise(eInternal,"Failed to copy old data, key %d, shmid %d, errno %d (%s)",key, shmid, errno, strerror(errno));
        failed=-6;
      }
    } else{
      failed = -7;
    }
  } else if (!failed){ // ptr->byte_size may be changed
    // we don't want to keep this worker's data, it is old
    ptr->byte_size = actual_byte_size;
  } else
    failed=-8;
  if (-1 != shmid) {
    return shmid;
  } else {
    return failed;
  }
}

/*
  Acquire memory by getting shmid, and then attaching it to a memory location,
    requires semaphore for locking/unlocking to be setup

  Note: should_keep_req_byte_size is a bool that decides how ptr->byte_size
        is handled. There may be a discrepancy between the requested memory size and the actual
        size of the memory block given. If it is false (0), ptr->byte_size will be modified
        to the actual memory size if there is a difference. This matters when dynamicaly resizing
        memory.
        Think of should_keep_req_byte_size as this worker requesting a size, others resizing,
        and !should_keep_req_byte_size as another worker requesting a size and this worker
        resizing
*/
VALUE
semian_shm_object_acquire_memory(VALUE self, VALUE permissions, VALUE should_keep_req_byte_size)
{
  semian_shm_object *ptr;
  TypedData_Get_Struct(self, semian_shm_object, &semian_shm_object_type, ptr);

  if (-1 == ptr->semid){
    rb_raise(eInternal, "semid not set, errno %d: (%s)", errno, strerror(errno));
    return self;
  }
  if (TYPE(permissions) != T_FIXNUM)
    rb_raise(rb_eTypeError, "expected integer for permissions");
  if (TYPE(should_keep_req_byte_size) != T_TRUE &&
      TYPE(should_keep_req_byte_size) != T_FALSE)
    rb_raise(rb_eTypeError, "expected true or false for should_keep_req_byte_size");

  int should_keep_req_byte_size_bool = RTEST(should_keep_req_byte_size);

  if (!semian_shm_object_lock(self))
    return Qfalse;


  int created = 0;
  key_t key = ptr->key;
  void *data_copy = NULL; // Will contain contents of old memory, if any
  size_t data_copy_byte_size = 0;
  int prev_mem_attach_count = 0;

  // Create/acquire memory and manage all resizing cases
  int shmid = create_and_resize_memory(key, ptr->byte_size, FIX2LONG(permissions), should_keep_req_byte_size_bool,
                                        &created, &data_copy, &data_copy_byte_size, &prev_mem_attach_count, ptr, self);
  if (shmid < 0) {// failed
    if (data_copy)
      free(data_copy);
    semian_shm_object_unlock(self);
    rb_raise(eSyscall, "shmget() failed at %d to acquire a memory shmid with key %d, size %zu, errno %d (%s)", shmid, key, ptr->byte_size, errno, strerror(errno));
  } else
    ptr->shmid = shmid;

  // Attach memory and call object_init_fn()
  if (0 == ptr->shm_address) {
    ptr->shm_address = shmat(ptr->shmid, (void *)0, 0);
    if (((void*)-1) == ptr->shm_address) {
      semian_shm_object_unlock(self);
      ptr->shm_address = 0;
      if (data_copy)
        free(data_copy);
      rb_raise(eSyscall, "shmat() failed to attach memory with shmid %d, size %zu, errno %d (%s)", ptr->shmid, ptr->byte_size, errno, strerror(errno));
    } else {
      ptr->object_init_fn(ptr->byte_size, ptr->shm_address, data_copy, data_copy_byte_size, prev_mem_attach_count);
    }
  }
  if (data_copy)
    free(data_copy);
  semian_shm_object_unlock(self);
  return self;
}

void
semian_shm_object_delete_memory_inner (semian_shm_object *ptr, int should_unlock, VALUE self, void *should_free)
{
  // This internal function may be called from a variety of contexts
  // Sometimes it is under a semaphore lock, sometimes it has extra malloc ptrs
  // Arguments handle these conditions

  if (0 != ptr->shm_address){
    if (-1 == shmdt(ptr->shm_address)) {
      if (should_unlock)
        semian_shm_object_unlock(self);
      if (should_free)
        free(should_free);
      rb_raise(eSyscall,"shmdt: no attached memory at %p, errno %d (%s)", ptr->shm_address, errno, strerror(errno));
    } else {
    }
    ptr->shm_address = 0;
  }

  if (-1 != ptr->shmid) {
    // Once IPC_RMID is set, no new shmgets can be made with key, and current values are invalid
    if (-1 == shmctl(ptr->shmid, IPC_RMID, 0)) {
      if (errno == EINVAL) {
        ptr->shmid = -1;
      } else {
        if (should_unlock)
          semian_shm_object_unlock(self);
        if (should_free)
          free(should_free);
        rb_raise(eSyscall,"shmctl: error flagging memory for removal with shmid %d, errno %d (%s)", ptr->shmid, errno, strerror(errno));
      }
    } else {
      ptr->shmid = -1;
    }
  }
}

VALUE
semian_shm_object_delete_memory (VALUE self)
{
  semian_shm_object *ptr;
  TypedData_Get_Struct(self, semian_shm_object, &semian_shm_object_type, ptr);

  if (!semian_shm_object_lock(self))
    return Qnil;

  semian_shm_object_delete_memory_inner(ptr, 1, self, NULL);

  semian_shm_object_unlock(self);
  return self;
}

VALUE
semian_shm_object_check_and_resize_if_needed(VALUE self) {
  semian_shm_object *ptr;
  TypedData_Get_Struct(self, semian_shm_object, &semian_shm_object_type, ptr);

  if (!semian_shm_object_lock(self))
    return Qnil;

  struct shmid_ds shm_info;
  int needs_resize = 0;
  if (-1 != ptr->shmid && -1 != shmctl(ptr->shmid, IPC_STAT, &shm_info)) {
    needs_resize = shm_info.shm_perm.mode & SHM_DEST;
  }

  if (needs_resize) {
    semian_shm_object_delete_memory_inner(ptr, 1, self, NULL);
    semian_shm_object_unlock(self);
    semian_shm_object_acquire_memory(self, LONG2FIX(ptr->permissions), Qfalse);
  } else {
    semian_shm_object_unlock(self);
  }
  return self;
}

static VALUE
semian_shm_object_semid(VALUE self)
{
  semian_shm_object *ptr;
  TypedData_Get_Struct(self, semian_shm_object, &semian_shm_object_type, ptr);
  semian_shm_object_check_and_resize_if_needed(self);
  return INT2NUM(ptr->semid);
}
static VALUE
semian_shm_object_shmid(VALUE self)
{
  semian_shm_object *ptr;
  TypedData_Get_Struct(self, semian_shm_object, &semian_shm_object_type, ptr);
  semian_shm_object_check_and_resize_if_needed(self);
  return INT2NUM(ptr->shmid);
}

static VALUE
semian_shm_object_byte_size(VALUE self)
{
  semian_shm_object *ptr;
  TypedData_Get_Struct(self, semian_shm_object, &semian_shm_object_type, ptr);
  semian_shm_object_check_and_resize_if_needed(self);
  int byte_size = ptr->byte_size;
  return INT2NUM(byte_size);
}

static VALUE
semian_shm_object_execute_atomically_with_block(VALUE self)
{
  if (!rb_block_given_p())
    rb_raise(rb_eArgError, "Expected block");
  return rb_yield(Qnil);
}

static VALUE
semian_shm_object_execute_atomically(VALUE self) {
  if (!semian_shm_object_lock(self))
    return Qnil;
  return rb_ensure(semian_shm_object_execute_atomically_with_block, self, semian_shm_object_unlock_all, self);
}

void
Init_semian_shm_object (void) {

  VALUE cSemianModule = rb_const_get(rb_cObject, rb_intern("Semian"));
  VALUE cSharedMemoryObject = rb_const_get(cSemianModule, rb_intern("SharedMemoryObject"));

  rb_define_alloc_func(cSharedMemoryObject, semian_shm_object_alloc);
  rb_define_method(cSharedMemoryObject, "_acquire", semian_shm_object_acquire, 3);
  rb_define_method(cSharedMemoryObject, "destroy", semian_shm_object_destroy, 0);
  rb_define_method(cSharedMemoryObject, "lock", semian_shm_object_lock, 0);
  rb_define_method(cSharedMemoryObject, "unlock", semian_shm_object_unlock, 0);
  rb_define_method(cSharedMemoryObject, "byte_size", semian_shm_object_byte_size, 0);

  rb_define_method(cSharedMemoryObject, "semid", semian_shm_object_semid, 0);
  rb_define_method(cSharedMemoryObject, "shmid", semian_shm_object_shmid, 0);
  rb_define_method(cSharedMemoryObject, "execute_atomically", semian_shm_object_execute_atomically, 0);

  rb_define_singleton_method(cSharedMemoryObject, "shared?", semian_shm_object_is_shared, 0);
  rb_define_singleton_method(cSharedMemoryObject, "_sizeof", semian_shm_object_sizeof, 1);

  decrement.sem_num = kSHMIndexTicketLock;
  decrement.sem_op = -1;
  decrement.sem_flg = SEM_UNDO;

  increment.sem_num = kSHMIndexTicketLock;
  increment.sem_op = 1;
  increment.sem_flg = SEM_UNDO;

  Init_semian_atomic_integer();
  Init_semian_sliding_window();
}

