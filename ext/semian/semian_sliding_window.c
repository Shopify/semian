#include "semian.h"

// struct sembuf { // found in sys/sem.h
//   unsigned short sem_num; /* semaphore number */
//   short sem_op; /* semaphore operation */
//   short sem_flg; /* operation flags */
// };

typedef struct {
  int counter;
  int window_length;
  long window[];
} shared_window_data;

typedef struct {
  //semaphore, shared memory data and pointer
  key_t key;
  size_t max_window_size;
  int lock_triggered;
  int permissions;
  int semid;
  int shmid;
  shared_window_data *shm_address;
} semian_window_data;

static const int kCBSemaphoreCount = 1; // # semaphores to be acquired
static const int kCBTicketMax = 1;
static const int kCBInitializeWaitTimeout = 5; /* seconds */
static const int kCBIndexTicketLock = 0;
static const int kCBInternalTimeout = 5; /* seconds */

static struct sembuf decrement; // = { kCBIndexTicketLock, -1, SEM_UNDO};
static struct sembuf increment; // = { kCBIndexTicketLock, 1, SEM_UNDO};

static VALUE eInternal, eSyscall, eTimeout; // Semian errors

static void semian_window_data_mark(void *ptr);
static void semian_window_data_free(void *ptr);
static size_t semian_window_data_memsize(const void *ptr);
static VALUE semian_window_data_alloc(VALUE klass);
static VALUE semian_window_data_init(VALUE self, VALUE name, VALUE size, VALUE permissions);
static VALUE semian_window_data_destroy(VALUE self);
static int create_semaphore_and_initialize(int key, int permissions);
static VALUE semian_window_data_acquire_semaphore (VALUE self, VALUE permissions);
static VALUE semian_window_data_delete_semaphore(VALUE self);
static VALUE semian_window_data_lock(VALUE self);
static VALUE semian_window_data_unlock(VALUE self);
static void *semian_window_data_lock_without_gvl(void *self);
static void *semian_window_data_unlock_without_gvl(void *self);
static VALUE semian_window_data_acquire_memory(VALUE self, VALUE permissions, VALUE should_keep_max_window_size);
static void semian_window_data_delete_memory_inner (semian_window_data *ptr, int should_unlock, VALUE self, void *should_free);
static VALUE semian_window_data_delete_memory (VALUE self);
static void semian_window_data_check_and_resize_if_needed (VALUE self);
static VALUE semian_window_data_get_counter(VALUE self);
static VALUE semian_window_data_set_counter(VALUE self, VALUE num);
static VALUE semian_window_data_semid(VALUE self);
static VALUE semian_window_data_shmid(VALUE self);
static VALUE semian_window_data_array_length(VALUE self);
static VALUE semian_window_data_set_push_back(VALUE self, VALUE num);
static VALUE semian_window_data_set_pop_back(VALUE self);
static VALUE semian_window_data_set_push_front(VALUE self, VALUE num);
static VALUE semian_window_data_set_pop_front(VALUE self);

static VALUE semian_window_data_is_shared(VALUE self);


// needed for TypedData_Make_Struct && TypedData_Get_Struct
static const rb_data_type_t
semian_window_data_type = {
  "semian_window_data",
  {
    semian_window_data_mark,
    semian_window_data_free,
    semian_window_data_memsize
  },
  NULL, NULL, RUBY_TYPED_FREE_IMMEDIATELY
};

/*
 * Functions that handle type and memory
*/
static void
semian_window_data_mark(void *ptr)
{
  /* noop */
}

static void
semian_window_data_free(void *ptr)
{
  semian_window_data *data = (semian_window_data *) ptr;


  // Under normal circumstances, memory use should be in the order of bytes,
  //   and shouldn't increase if the same key/id is used
  //   so there is no need to call this unless certain all other semian processes are stopped
  //   (also raises concurrency errors: "object allocation during garbage collection phase")

  //semian_window_data_delete_memory_inner (data);

  xfree(data);
}

static size_t
semian_window_data_memsize(const void *ptr)
{
  return sizeof(semian_window_data);
}

static VALUE
semian_window_data_alloc(VALUE klass)
{
  VALUE obj;
  semian_window_data *ptr;

  obj = TypedData_Make_Struct(klass, semian_window_data, &semian_window_data_type, ptr);
  return obj;
}






/*
 * Init function exposed as ._initialize() that is delegated by .initialize()
 */
static VALUE
semian_window_data_init(VALUE self, VALUE id, VALUE size, VALUE permissions)
{
  semian_window_data *ptr;
  TypedData_Get_Struct(self, semian_window_data, &semian_window_data_type, ptr);

  if (TYPE(id) != T_SYMBOL && TYPE(id) != T_STRING)
    rb_raise(rb_eTypeError, "id must be a symbol or string");
  if (TYPE(size) != T_FIXNUM)
    rb_raise(rb_eTypeError, "expected integer for max_window_size");
  if (TYPE(permissions) != T_FIXNUM)
    rb_raise(rb_eTypeError, "expected integer for permissions");

  if (NUM2SIZET(size) <= 0)
    rb_raise(rb_eArgError, "max_window_size must be larger than 0");

  const char *id_str = NULL;
  if (TYPE(id) == T_SYMBOL) {
    id_str = rb_id2name(rb_to_id(id));
  } else if (TYPE(id) == T_STRING) {
    id_str = RSTRING_PTR(id);
  }
  ptr->key = generate_key(id_str);
  //rb_warn("converted name %s to key %d", id_str, ptr->key);

  // Guarantee max_window_size >=1 or error thrown
  ptr->max_window_size = NUM2SIZET(size);

  // id's default to -1
  ptr->semid = -1;
  ptr->shmid = -1;
  // addresses default to NULL
  ptr->shm_address = 0;
  ptr->lock_triggered = 0;
  ptr->permissions = FIX2LONG(permissions);

  semian_window_data_acquire_semaphore(self, permissions);
  semian_window_data_acquire_memory(self, permissions, Qtrue);

  return self;
}

static VALUE
semian_window_data_destroy(VALUE self)
{
  semian_window_data_delete_memory(self);
  semian_window_data_delete_semaphore(self);
  return self;
}


static int
create_semaphore_and_initialize(int key, int permissions)
{
  int semid = 0;
  int flags = 0;

  flags = IPC_EXCL | IPC_CREAT | permissions;

  semid = semget(key, kCBSemaphoreCount, flags);
  if (semid >= 0) {
    if (-1 == semctl(semid, 0, SETVAL, kCBTicketMax)) {
      rb_warn("semctl: failed to set semaphore with semid %d, position 0 to %d", semid, 1);
      raise_semian_syscall_error("semctl()", errno);
    }
  } else if (semid == -1 && errno == EEXIST) {
    flags &= ~IPC_EXCL;
    semid = semget(key, kCBSemaphoreCount, flags);
  }
  return semid;
}


/*
 * Create or acquire previously made semaphore
 */

static VALUE
semian_window_data_acquire_semaphore (VALUE self, VALUE permissions)
{
  // Function flow, semaphore creation methods are
  //   borrowed from semian.c since they have been previously tested

  semian_window_data *ptr;
  TypedData_Get_Struct(self, semian_window_data, &semian_window_data_type, ptr);

  if (TYPE(permissions) != T_FIXNUM)
    rb_raise(rb_eTypeError, "expected integer for permissions");

  // bool for initializing (configure_tickets) or not
  key_t key = ptr->key;
  int semid = create_semaphore_and_initialize(key, FIX2LONG(permissions));
  if (-1 == semid) {
    raise_semian_syscall_error("semget()", errno);
  }
  ptr->semid = semid;

  set_semaphore_permissions(ptr->semid, FIX2LONG(permissions));

  return self;
}


static VALUE
semian_window_data_delete_semaphore(VALUE self)
{
  semian_window_data *ptr;
  TypedData_Get_Struct(self, semian_window_data, &semian_window_data_type, ptr);
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
    //rb_warn("semctl: semaphore set with semid %d deleted", ptr->semid);
    ptr->semid = -1;
  }
  return self;
}




/*
 * semian_window_data_lock/unlock and associated functions decrement/increment semaphore
 */

static VALUE
semian_window_data_lock(VALUE self)
{
  return (VALUE) WITHOUT_GVL(semian_window_data_lock_without_gvl, (void *)self, RUBY_UBF_IO, NULL);
}

static void *
semian_window_data_lock_without_gvl(void *self)
{
  semian_window_data *ptr;
  TypedData_Get_Struct((VALUE)self, semian_window_data, &semian_window_data_type, ptr);
  if (ptr->lock_triggered)
    return (void *)Qtrue;
  if (-1 == ptr->semid){
    rb_raise(eInternal, "semid not set, errno %d: (%s)", errno, strerror(errno));
    return (void *)Qfalse;
  }
  VALUE retval;

  struct timespec ts = { 0 };
  ts.tv_sec = kCBInternalTimeout;

  if (-1 == semtimedop(ptr->semid,&decrement,1, &ts)) {
    rb_raise(eInternal, "error acquiring semaphore lock to mutate circuit breaker structure, %d: (%s)", errno, strerror(errno));
    retval=Qfalse;
  } else
    retval=Qtrue;

  ptr->lock_triggered = 1;
  return (void *)retval;
}

static VALUE
semian_window_data_unlock(VALUE self)
{
  return (VALUE) WITHOUT_GVL(semian_window_data_unlock_without_gvl, (void *)self, RUBY_UBF_IO, NULL);
}

static void *
semian_window_data_unlock_without_gvl(void *self)
{
  semian_window_data *ptr;
  TypedData_Get_Struct((VALUE)self, semian_window_data, &semian_window_data_type, ptr);
  if (!(ptr->lock_triggered))
    return (void *)Qtrue;
  if (-1 == ptr->semid){
    rb_raise(eInternal, "semid not set, errno %d: (%s)", errno, strerror(errno));
    return (void *)Qfalse;
  }
  VALUE retval;

  if (-1 == semop(ptr->semid,&increment,1)) {
    rb_raise(eInternal, "error unlocking semaphore, %d (%s)", errno, strerror(errno));
    retval=Qfalse;
  } else
    retval=Qtrue;

  ptr->lock_triggered = 0;
  //rb_warn("semop unlock success");
  return (void *)retval;
}


static int
create_and_resize_memory(key_t key, int max_window_size, long permissions, int should_keep_max_window_size_bool,
  int *created, shared_window_data **data_copy, semian_window_data *ptr, VALUE self) {

  // Below will handle acquiring/creating new memory, and possibly resizing the
  //   memory or the ptr->max_window_size depending on
  //   should_keep_max_window_size_bool

  int shmid=-1;
  int failed=0;

  int requested_byte_size = 2*sizeof(int) + max_window_size * sizeof(long);
  int flags = IPC_CREAT | IPC_EXCL | permissions;

  int actual_byte_size = 0;

  // We fill both actual_byte_size and requested_byte_size
  // Logic matrix:
  //                                         actual=>req     | actual=req |   actual<req
  //                                    -----------------------------------------
  //  should_keep_max_window_size_bool | no err, shrink mem  |   no err   | error, expand mem
  // !should_keep_max_window_size_bool | no err, ++ max size |   no err   | error, -- max size

  if (-1 == (shmid = shmget( key, requested_byte_size, flags))) {
    if (errno == EEXIST) {
      if (-1 != (shmid = shmget(key, requested_byte_size, flags & ~IPC_EXCL))) {
        struct shmid_ds shm_info;
        if (-1 != shmctl(shmid, IPC_STAT, &shm_info)){
          actual_byte_size = shm_info.shm_segsz;
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

  if (should_keep_max_window_size_bool && !failed) { // memory resizing may occur
    // We flag old mem by IPC_RMID, copy data, and fix it values if it needs fixing

    if (actual_byte_size != requested_byte_size) {
      shared_window_data *data;

      if ((void *)-1 != (data = shmat(shmid, (void *)0, 0))) {

        *data_copy = malloc(actual_byte_size);
        memcpy(*data_copy,data,actual_byte_size);
        ptr->shmid=shmid;
        ptr->shm_address = data;
        semian_window_data_delete_memory_inner(ptr, 1, self, *data_copy);

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
  } else if (!failed){ // ptr->max_window_size may be changed
    ptr->max_window_size = (actual_byte_size - 2*sizeof(int))/(sizeof(long));
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

  Note: should_keep_max_window_size is a bool that decides how ptr->max_window_size
        is handled. There may be a discrepancy between the requested memory size and the actual
        size of the memory block given. If it is false (0), ptr->max_window_size will be modified
        to the actual memory size if there is a difference. This matters when dynamicaly resizing
        memory.
        Think of should_keep_max_window_size as this worker requesting a size, others resizing,
        and !should_keep_max_window_size as another worker requesting a size and this worker
        resizing
*/
static VALUE
semian_window_data_acquire_memory(VALUE self, VALUE permissions, VALUE should_keep_max_window_size)
{
  semian_window_data *ptr;
  TypedData_Get_Struct(self, semian_window_data, &semian_window_data_type, ptr);

  if (-1 == ptr->semid){
    rb_raise(eInternal, "semid not set, errno %d: (%s)", errno, strerror(errno));
    return self;
  }
  if (TYPE(permissions) != T_FIXNUM)
    rb_raise(rb_eTypeError, "expected integer for permissions");
  if (TYPE(should_keep_max_window_size) != T_TRUE &&
      TYPE(should_keep_max_window_size) != T_FALSE)
    rb_raise(rb_eTypeError, "expected true or false for should_keep_max_window_size");

  int should_keep_max_window_size_bool = RTEST(should_keep_max_window_size);

  if (!semian_window_data_lock(self))
    return Qfalse;


  int created = 0;
  key_t key = ptr->key;
  shared_window_data *data_copy = NULL; // Will contain contents of old memory, if any

  int shmid = create_and_resize_memory(key, ptr->max_window_size, FIX2LONG(permissions), should_keep_max_window_size_bool, &created, &data_copy, ptr, self);
  if (shmid < 0) {// failed
    if (data_copy)
      free(data_copy);
    semian_window_data_unlock(self);
    rb_raise(eSyscall, "shmget() failed at %d to acquire a memory shmid with key %d, size %zu, errno %d (%s)", shmid, key, ptr->max_window_size, errno, strerror(errno));
  } else
    ptr->shmid = shmid;


  if (0 == ptr->shm_address) {
    ptr->shm_address = shmat(ptr->shmid, (void *)0, 0);
    if (((void*)-1) == ptr->shm_address) {
      semian_window_data_unlock(self);
      ptr->shm_address = 0;
      if (data_copy)
        free(data_copy);
      rb_raise(eSyscall, "shmat() failed to attach memory with shmid %d, size %zu, errno %d (%s)", ptr->shmid, ptr->max_window_size, errno, strerror(errno));
    } else {
      if (created) {
        if (data_copy) {
          // transfer data over
          ptr->shm_address->counter = data_copy->counter;
          ptr->shm_address->window_length = fmin(ptr->max_window_size-1, data_copy->window_length);

          // Copy the most recent ptr->shm_address->window_length numbers to new memory
          memcpy(&(ptr->shm_address->window),
                ((long *)(&(data_copy->window[0])))+data_copy->window_length-ptr->shm_address->window_length,
                ptr->shm_address->window_length * sizeof(long));
        } else {
          shared_window_data *data = ptr->shm_address;
          data->counter = 0;
          data->window_length = 0;
          for (int i=0; i< data->window_length; ++i)
            data->window[i]=0;
        }
      }
    }
  }
  if (data_copy)
    free(data_copy);
  semian_window_data_unlock(self);
  return self;
}

static void
semian_window_data_delete_memory_inner (semian_window_data *ptr, int should_unlock, VALUE self, void *should_free)
{
  // This internal function may be called from a variety of contexts
  // Sometimes it is under a semaphore lock, sometimes it has extra malloc ptrs
  // Arguments handle these conditions

  if (0 != ptr->shm_address){
    if (-1 == shmdt(ptr->shm_address)) {
      if (should_unlock)
        semian_window_data_unlock(self);
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
          semian_window_data_unlock(self);
        if (should_free)
          free(should_free);
        rb_raise(eSyscall,"shmctl: error flagging memory for removal with shmid %d, errno %d (%s)", ptr->shmid, errno, strerror(errno));
      }
    } else {
      ptr->shmid = -1;
    }
  }
}


static VALUE
semian_window_data_delete_memory (VALUE self)
{
  semian_window_data *ptr;
  TypedData_Get_Struct(self, semian_window_data, &semian_window_data_type, ptr);

  if (!semian_window_data_lock(self))
    return self;

  semian_window_data_delete_memory_inner(ptr, 1, self, NULL);

  semian_window_data_unlock(self);
  return self;
}


static void //bool
semian_window_data_check_and_resize_if_needed(VALUE self) {
  semian_window_data *ptr;
  TypedData_Get_Struct(self, semian_window_data, &semian_window_data_type, ptr);

  if (!semian_window_data_lock(self))
    return;

  struct shmid_ds shm_info;
  int needs_resize = 0;
  if (-1 != ptr->shmid && -1 != shmctl(ptr->shmid, IPC_STAT, &shm_info)) {
    needs_resize = shm_info.shm_perm.mode & SHM_DEST;
  }

  if (needs_resize) {
    semian_window_data_delete_memory_inner(ptr, 1, self, NULL);
    semian_window_data_unlock(self);
    semian_window_data_acquire_memory(self, LONG2FIX(ptr->permissions), Qfalse);
  } else {
    semian_window_data_unlock(self);
  }
}


/*
 * Below are methods for counter, semid, shmid, and array pop, push, peek at front and back
 *  and clear, length
 */

static VALUE
semian_window_data_get_counter(VALUE self)
{
  semian_window_data *ptr;
  TypedData_Get_Struct(self, semian_window_data, &semian_window_data_type, ptr);

  // check shared memory for NULL
  if (0 == ptr->shm_address)
    return Qnil;
  semian_window_data_check_and_resize_if_needed(self);
  if (!semian_window_data_lock(self))
    return Qnil;

  int counter = ptr->shm_address->counter;

  semian_window_data_unlock(self);
  return INT2NUM(counter);
}

static VALUE
semian_window_data_set_counter(VALUE self, VALUE num)
{
  semian_window_data *ptr;
  TypedData_Get_Struct(self, semian_window_data, &semian_window_data_type, ptr);

  if (0 == ptr->shm_address)
    return Qnil;

  if (TYPE(num) != T_FIXNUM && TYPE(num) != T_FLOAT)
    return Qnil;
  semian_window_data_check_and_resize_if_needed(self);
  if (!semian_window_data_lock(self))
    return Qnil;

  ptr->shm_address->counter = NUM2INT(num);

  semian_window_data_unlock(self);
  return num;
}


static VALUE
semian_window_data_semid(VALUE self)
{
  semian_window_data *ptr;
  TypedData_Get_Struct(self, semian_window_data, &semian_window_data_type, ptr);
  semian_window_data_check_and_resize_if_needed(self);
  return INT2NUM(ptr->semid);
}
static VALUE
semian_window_data_shmid(VALUE self)
{
  semian_window_data *ptr;
  TypedData_Get_Struct(self, semian_window_data, &semian_window_data_type, ptr);
  semian_window_data_check_and_resize_if_needed(self);
  return INT2NUM(ptr->shmid);
}

static VALUE
semian_window_data_max_window_size(VALUE self)
{
  semian_window_data *ptr;
  TypedData_Get_Struct(self, semian_window_data, &semian_window_data_type, ptr);
  semian_window_data_check_and_resize_if_needed(self);
  int max_window_size =ptr->max_window_size;
  return INT2NUM(max_window_size);
}

static VALUE
semian_window_data_array_length(VALUE self)
{
  semian_window_data *ptr;
  TypedData_Get_Struct(self, semian_window_data, &semian_window_data_type, ptr);
  if (0 == ptr->shm_address)
    return Qnil;
  semian_window_data_check_and_resize_if_needed(self);
  if (!semian_window_data_lock(self))
    return Qnil;
  int window_length =ptr->shm_address->window_length;
  semian_window_data_unlock(self);
  return INT2NUM(window_length);
}

static VALUE
semian_window_data_set_push_back(VALUE self, VALUE num)
{
  semian_window_data *ptr;
  TypedData_Get_Struct(self, semian_window_data, &semian_window_data_type, ptr);
  if (0 == ptr->shm_address)
    return Qnil;
  if (TYPE(num) != T_FIXNUM && TYPE(num) != T_FLOAT && TYPE(num) != T_BIGNUM)
    return Qnil;
  semian_window_data_check_and_resize_if_needed(self);
  if (!semian_window_data_lock(self))
    return Qnil;

  shared_window_data *data = ptr->shm_address;
  if (data->window_length == ptr->max_window_size) {
    for (int i=1; i< ptr->max_window_size; ++i){
      data->window[i-1] = data->window[i];
    }
    --(data->window_length);
  }
  data->window[(data->window_length)] = NUM2LONG(num);
  ++(data->window_length);
  semian_window_data_unlock(self);
  return self;
}

static VALUE
semian_window_data_set_pop_back(VALUE self)
{
  semian_window_data *ptr;
  TypedData_Get_Struct(self, semian_window_data, &semian_window_data_type, ptr);
  if (0 == ptr->shm_address)
    return Qnil;
  semian_window_data_check_and_resize_if_needed(self);
  if (!semian_window_data_lock(self))
    return Qnil;

  VALUE retval;
  shared_window_data *data = ptr->shm_address;
  if (0 == data->window_length)
    retval = Qnil;
  else {
    retval = LONG2NUM(data->window[data->window_length-1]);
    --(data->window_length);
  }

  semian_window_data_unlock(self);
  return retval;
}

static VALUE
semian_window_data_set_pop_front(VALUE self)
{
  semian_window_data *ptr;
  TypedData_Get_Struct(self, semian_window_data, &semian_window_data_type, ptr);
  if (0 == ptr->shm_address)
    return Qnil;
  semian_window_data_check_and_resize_if_needed(self);
  if (!semian_window_data_lock(self))
    return Qnil;

  VALUE retval;
  shared_window_data *data = ptr->shm_address;
  if (0 >= data->window_length)
    retval = Qnil;
  else {
    retval = LONG2NUM(data->window[0]);
    for (int i=0; i<data->window_length-1; ++i)
      data->window[i]=data->window[i+1];
    --(data->window_length);
  }

  semian_window_data_unlock(self);
  return retval;
}

static VALUE
semian_window_data_set_push_front(VALUE self, VALUE num)
{
  semian_window_data *ptr;
  TypedData_Get_Struct(self, semian_window_data, &semian_window_data_type, ptr);
  if (0 == ptr->shm_address)
    return Qnil;
  if (TYPE(num) != T_FIXNUM && TYPE(num) != T_FLOAT && TYPE(num) != T_BIGNUM)
    return Qnil;
  semian_window_data_check_and_resize_if_needed(self);
  if (!semian_window_data_lock(self))
    return Qnil;

  long val = NUM2LONG(num);
  shared_window_data *data = ptr->shm_address;

  int i=data->window_length;
  for (; i>0; --i)
    data->window[i]=data->window[i-1];

  data->window[0] = val;
  ++(data->window_length);
  if (data->window_length>ptr->max_window_size)
    data->window_length=ptr->max_window_size;

  semian_window_data_unlock(self);
  return self;
}

static VALUE
semian_window_data_array_clear(VALUE self)
{
  semian_window_data *ptr;
  TypedData_Get_Struct(self, semian_window_data, &semian_window_data_type, ptr);
  if (0 == ptr->shm_address)
    return Qnil;
  semian_window_data_check_and_resize_if_needed(self);
  if (!semian_window_data_lock(self))
    return Qnil;
  ptr->shm_address->window_length=0;

  semian_window_data_unlock(self);
  return self;
}

static VALUE
semian_window_data_array_first(VALUE self)
{
  semian_window_data *ptr;
  TypedData_Get_Struct(self, semian_window_data, &semian_window_data_type, ptr);
  if (0 == ptr->shm_address)
    return Qnil;
  semian_window_data_check_and_resize_if_needed(self);
  if (!semian_window_data_lock(self))
    return Qnil;

  VALUE retval;
  if (ptr->shm_address->window_length >=1)
    retval = LONG2NUM(ptr->shm_address->window[0]);
  else
    retval = Qnil;

  semian_window_data_unlock(self);
  return retval;
}

static VALUE
semian_window_data_array_last(VALUE self)
{
  semian_window_data *ptr;
  TypedData_Get_Struct(self, semian_window_data, &semian_window_data_type, ptr);
  if (0 == ptr->shm_address)
    return Qnil;
  semian_window_data_check_and_resize_if_needed(self);
  if (!semian_window_data_lock(self))
    return Qnil;

  VALUE retval;
  if (ptr->shm_address->window_length > 0)
    retval = LONG2NUM(ptr->shm_address->window[ptr->shm_address->window_length-1]);
  else
    retval = Qnil;

  semian_window_data_unlock(self);
  return retval;
}

static VALUE
semian_window_data_is_shared(VALUE self)
{
  return Qtrue;
}

void
Init_semian_sliding_window (void) {

  VALUE cSemianModule = rb_const_get(rb_cObject, rb_intern("Semian"));

  VALUE cCircuitBreakerSharedData = rb_const_get(cSemianModule, rb_intern("SlidingWindow"));

  rb_define_alloc_func(cCircuitBreakerSharedData, semian_window_data_alloc);
  rb_define_method(cCircuitBreakerSharedData, "_initialize", semian_window_data_init, 3);
  rb_define_method(cCircuitBreakerSharedData, "_destroy", semian_window_data_destroy, 0);
  //rb_define_method(cCircuitBreakerSharedData, "acquire_semaphore", semian_window_data_acquire_semaphore, 1);
  //rb_define_method(cCircuitBreakerSharedData, "delete_semaphore", semian_window_data_delete_semaphore, 0);
  //rb_define_method(cCircuitBreakerSharedData, "lock", semian_window_data_lock, 0);
  //rb_define_method(cCircuitBreakerSharedData, "unlock", semian_window_data_unlock, 0);
  rb_define_method(cCircuitBreakerSharedData, "acquire_memory", semian_window_data_acquire_memory, 2);
  rb_define_method(cCircuitBreakerSharedData, "delete_memory", semian_window_data_delete_memory, 0);
  rb_define_method(cCircuitBreakerSharedData, "max_window_size", semian_window_data_max_window_size, 0);

  rb_define_method(cCircuitBreakerSharedData, "semid", semian_window_data_semid, 0);
  rb_define_method(cCircuitBreakerSharedData, "shmid", semian_window_data_shmid, 0);
  rb_define_method(cCircuitBreakerSharedData, "successes", semian_window_data_get_counter, 0);
  rb_define_method(cCircuitBreakerSharedData, "successes=", semian_window_data_set_counter, 1);

  rb_define_method(cCircuitBreakerSharedData, "size", semian_window_data_array_length, 0);
  rb_define_method(cCircuitBreakerSharedData, "count", semian_window_data_array_length, 0);
  rb_define_method(cCircuitBreakerSharedData, "<<", semian_window_data_set_push_back, 1);
  rb_define_method(cCircuitBreakerSharedData, "push", semian_window_data_set_push_back, 1);
  rb_define_method(cCircuitBreakerSharedData, "pop", semian_window_data_set_pop_back, 0);
  rb_define_method(cCircuitBreakerSharedData, "shift", semian_window_data_set_pop_front, 0);
  rb_define_method(cCircuitBreakerSharedData, "unshift", semian_window_data_set_push_front, 1);
  rb_define_method(cCircuitBreakerSharedData, "clear", semian_window_data_array_clear, 0);
  rb_define_method(cCircuitBreakerSharedData, "first", semian_window_data_array_first, 0);
  rb_define_method(cCircuitBreakerSharedData, "last", semian_window_data_array_last, 0);

  rb_define_singleton_method(cCircuitBreakerSharedData, "shared?", semian_window_data_is_shared, 0);

  eInternal = rb_const_get(cSemianModule, rb_intern("InternalError"));
  eSyscall = rb_const_get(cSemianModule, rb_intern("SyscallError"));
  eTimeout = rb_const_get(cSemianModule, rb_intern("TimeoutError"));

  decrement.sem_num = kCBIndexTicketLock;
  decrement.sem_op = -1;
  decrement.sem_flg = SEM_UNDO;

  increment.sem_num = kCBIndexTicketLock;
  increment.sem_op = 1;
  increment.sem_flg = SEM_UNDO;

  /* Maximum number of tickets available on this system. */
  rb_const_get(cSemianModule, rb_intern("MAX_TICKETS"));
}
