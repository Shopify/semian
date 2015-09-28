#include <ruby.h>
#include <stdio.h>

#include <errno.h>
#include <sys/types.h>
#include <sys/ipc.h>
#include <sys/sem.h>
#include <sys/shm.h>
#include <sys/time.h>

#include <openssl/sha.h>
#include <unistd.h>
#include <stdbool.h>

// needed for semctl
union semun {
  int              val;    /* Value for SETVAL */
  struct semid_ds *buf;    /* Buffer for IPC_STAT, IPC_SET */
  unsigned short  *array;  /* Array for GETALL, SETALL */
  struct seminfo  *__buf;  /* Buffer for IPC_INFO
                             (Linux-specific) */
};

#if defined(HAVE_RB_THREAD_CALL_WITHOUT_GVL) && defined(HAVE_RUBY_THREAD_H)
// 2.0
#include <ruby/thread.h>
#define WITHOUT_GVL(fn,a,ubf,b) rb_thread_call_without_gvl((fn),(a),(ubf),(b))
#elif defined(HAVE_RB_THREAD_BLOCKING_REGION)
 // 1.9
typedef VALUE (*my_blocking_fn_t)(void*);
#define WITHOUT_GVL(fn,a,ubf,b) rb_thread_blocking_region((my_blocking_fn_t)(fn),(a),(ubf),(b))
#endif

// struct sembuf { // found in sys/sem.h
//   unsigned short sem_num; /* semaphore number */
//   short sem_op; /* semaphore operation */
//   short sem_flg; /* operation flags */
// };

typedef struct {
  int successes;
  int arr_length;
  double errors[];
} shared_cb_data;

typedef struct {
  //semaphore, shared memory data and pointer
  key_t key;
  size_t arr_max_size;
  bool lock_triggered;
  int semid;
  int shmid;
  shared_cb_data *shm_address;
} semian_cb_data;

static int system_max_semaphore_count;
static const int kCBSemaphoreCount = 1; // # semaphores to be acquired
static const int kCBTicketMax = 1;
static const int kCBInitializeWaitTimeout = 5; /* seconds */
static const int kCBIndexTicketLock = 0;
static const int kCBInternalTimeout = 5; /* seconds */

static struct sembuf decrement; // = { kCBIndexTicketLock, -1, SEM_UNDO};
static struct sembuf increment; // = { kCBIndexTicketLock, 1, SEM_UNDO};

static VALUE eInternal, eSyscall, eTimeout; // Semian errors

static void semian_cb_data_mark(void *ptr);
static void semian_cb_data_free(void *ptr);
static size_t semian_cb_data_memsize(const void *ptr);
static VALUE semian_cb_data_alloc(VALUE klass);
static VALUE semian_cb_data_init(VALUE self, VALUE name, VALUE size, VALUE permissions);
static VALUE semian_cb_data_clean(VALUE self);
static void set_semaphore_permissions(int sem_id, int permissions);
static void configure_tickets(int sem_id, int tickets, int should_initialize);
static int create_semaphore(int key, int permissions, int *created);
static VALUE semian_cb_data_acquire_semaphore (VALUE self, VALUE permissions);
static VALUE semian_cb_data_delete_semaphore(VALUE self);
static VALUE semian_cb_data_lock(VALUE self);
static VALUE semian_cb_data_unlock(VALUE self);
static void *semian_cb_data_lock_without_gvl(void *self);
static void *semian_cb_data_unlock_without_gvl(void *self);
static VALUE semian_cb_data_acquire_memory(VALUE self, VALUE permissions);
static void semian_cb_data_delete_memory_inner (semian_cb_data *ptr);
static VALUE semian_cb_data_delete_memory (VALUE self);
static VALUE semian_cb_data_get_successes(VALUE self);
static VALUE semian_cb_data_set_successes(VALUE self, VALUE num);
static VALUE semian_cb_data_semid(VALUE self);
static VALUE semian_cb_data_shmid(VALUE self);
static VALUE semian_cb_data_array_at_index(VALUE self, VALUE idx);
static VALUE semian_cb_data_array_set_index(VALUE self, VALUE idx, VALUE val);
static VALUE semian_cb_data_array_length(VALUE self);
static VALUE semian_cb_data_set_push_back(VALUE self, VALUE num);
static VALUE semian_cb_data_set_pop_back(VALUE self);
static VALUE semian_cb_data_set_push_front(VALUE self, VALUE num);
static VALUE semian_cb_data_set_pop_front(VALUE self);

// needed for TypedData_Make_Struct && TypedData_Get_Struct
static const rb_data_type_t
semian_cb_data_type = {
  "semian_cb_data",
  {
    semian_cb_data_mark,
    semian_cb_data_free,
    semian_cb_data_memsize
  },
  NULL, NULL, RUBY_TYPED_FREE_IMMEDIATELY
};

/*
 * Generate key
 */
static key_t
generate_key(const char *name)
{
  union {
    unsigned char str[SHA_DIGEST_LENGTH];
    key_t key;
  } digest;
  SHA1((const unsigned char *) name, strlen(name), digest.str);
  /* TODO: compile-time assertion that sizeof(key_t) > SHA_DIGEST_LENGTH */
  return digest.key;
}

/*
 * Log errors
 */
static void
raise_semian_syscall_error(const char *syscall, int error_num)
{
  rb_raise(eSyscall, "%s failed, errno %d (%s)", syscall, error_num, strerror(error_num));
}

/*
 * Functions that handle type and memory
*/
static void
semian_cb_data_mark(void *ptr)
{
  /* noop */
}

static void
semian_cb_data_free(void *ptr)
{
  semian_cb_data *data = (semian_cb_data *) ptr;


  // Under normal circumstances, memory use should be in the order of bytes,
  //   and shouldn't increase if the same key/id is used
  //   so there is no need to call this unless certain all other semian processes are stopped
  //   (also raises concurrency errors: "object allocation during garbage collection phase")

  //semian_cb_data_delete_memory_inner (data);

  xfree(data);
}

static size_t
semian_cb_data_memsize(const void *ptr)
{
  return sizeof(semian_cb_data);
}

static VALUE
semian_cb_data_alloc(VALUE klass)
{
  VALUE obj;
  semian_cb_data *ptr;

  obj = TypedData_Make_Struct(klass, semian_cb_data, &semian_cb_data_type, ptr);
  return obj;
}






/*
 * Init function exposed as ._initialize() that is delegated by .initialize()
 */
static VALUE
semian_cb_data_init(VALUE self, VALUE id, VALUE size, VALUE permissions)
{
  semian_cb_data *ptr;
  TypedData_Get_Struct(self, semian_cb_data, &semian_cb_data_type, ptr);

  if (TYPE(id) != T_SYMBOL && TYPE(id) != T_STRING)
    rb_raise(rb_eTypeError, "id must be a symbol or string");
  if (TYPE(size) != T_FIXNUM /*|| TYPE(size) != T_BIGNUM*/)
    rb_raise(rb_eTypeError, "expected integer for arr_max_size");
  if (TYPE(permissions) != T_FIXNUM)
    rb_raise(rb_eTypeError, "expected integer for permissions");

  if (NUM2SIZET(size) <= 0)
    rb_raise(rb_eArgError, "arr_max_size must be larger than 0");

  const char *id_str = NULL;
  if (TYPE(id) == T_SYMBOL) {
    id_str = rb_id2name(rb_to_id(id));
  } else if (TYPE(id) == T_STRING) {
    id_str = RSTRING_PTR(id);
  }
  ptr->key = generate_key(id_str);
  //rb_warn("converted name %s to key %d", id_str, ptr->key);

  // Guarantee arr_max_size >=1 or error thrown
  ptr->arr_max_size = NUM2SIZET(size);

  // id's default to -1
  ptr->semid = -1;
  ptr->shmid = -1;
  // addresses default to NULL
  ptr->shm_address = 0;
  ptr->lock_triggered = false;

  semian_cb_data_acquire_semaphore(self, permissions);
  semian_cb_data_acquire_memory(self, permissions);

  return self;
}

static VALUE
semian_cb_data_clean(VALUE self)
{
  semian_cb_data_delete_memory(self);
  semian_cb_data_delete_semaphore(self);
  return self;
}



/*
 * Functions set_semaphore_permissions, configure_tickets, create_semaphore
 * are taken from semian.c with extra code removed
 */
static void
set_semaphore_permissions(int sem_id, int permissions)
{
  union semun sem_opts;
  struct semid_ds stat_buf;

  sem_opts.buf = &stat_buf;
  semctl(sem_id, 0, IPC_STAT, sem_opts);
  if ((stat_buf.sem_perm.mode & 0xfff) != permissions) {
    stat_buf.sem_perm.mode &= ~0xfff;
    stat_buf.sem_perm.mode |= permissions;
    semctl(sem_id, 0, IPC_SET, sem_opts);
  }
}


static void
configure_tickets(int sem_id, int tickets, int should_initialize)
{
  struct timeval start_time, cur_time;

  if (should_initialize) {
    if (-1 == semctl(sem_id, 0, SETVAL, kCBTicketMax)) {
      rb_warn("semctl: failed to set semaphore with semid %d, position 0 to %d", sem_id, 1);
      raise_semian_syscall_error("semctl()", errno);
    } else {
      //rb_warn("semctl: set semaphore with semid %d, position 0 to %d", sem_id, 1);
    }
  } else if (tickets > 0) {
    // it's possible that we haven't actually initialized the
    // semaphore structure yet - wait a bit in that case
    int ret;
    if (0 == (ret = semctl(sem_id, 0, GETVAL))) {
      gettimeofday(&start_time, NULL);
      while (0 == (ret = semctl(sem_id, 0, GETVAL))) { // loop while value == 0
        usleep(10000); /* 10ms */
        gettimeofday(&cur_time, NULL);
        if ((cur_time.tv_sec - start_time.tv_sec) > kCBInitializeWaitTimeout) {
          rb_raise(eInternal, "timeout waiting for semaphore initialization");
        }
      }
      if (-1 == ret) {
        rb_raise(eInternal, "error getting max ticket count, errno: %d (%s)", errno, strerror(errno));
      }
    }

    // Rest of the function (originally from semian.c) was removed since it isn't needed
  }
}

static int
create_semaphore(int key, int permissions, int *created)
{
  int semid = 0;
  int flags = 0;

  *created = 0;
  flags = IPC_EXCL | IPC_CREAT | permissions;

  semid = semget(key, kCBSemaphoreCount, flags);
  if (semid >= 0) {
    *created = 1;
    //rb_warn("semget: received %d semaphore(s) with key %d, semid %d", kCBSemaphoreCount, key, semid);
  } else if (semid == -1 && errno == EEXIST) {
    flags &= ~IPC_EXCL;
    semid = semget(key, kCBSemaphoreCount, flags);
    //rb_warn("semget: retrieved existing semaphore with key %d, semid %d", key, semid);
  }
  return semid;
}




/*
 * Create or acquire previously made semaphore
 */

static VALUE
semian_cb_data_acquire_semaphore (VALUE self, VALUE permissions)
{
  // Function flow, semaphore creation methods are
  //   borrowed from semian.c since they have been previously tested

  semian_cb_data *ptr;
  TypedData_Get_Struct(self, semian_cb_data, &semian_cb_data_type, ptr);

  if (TYPE(permissions) != T_FIXNUM)
    rb_raise(rb_eTypeError, "expected integer for permissions");

  // bool for initializing (configure_tickets) or not
  int created = 0;
  key_t key = ptr->key;
  int semid = create_semaphore(key, FIX2LONG(permissions), &created);
  if (-1 == semid) {
    raise_semian_syscall_error("semget()", errno);
  }
  ptr->semid = semid;

  // initialize to 1 and set permissions
  configure_tickets(ptr->semid, kCBTicketMax, created);
  set_semaphore_permissions(ptr->semid, FIX2LONG(permissions));

  return self;
}


static VALUE
semian_cb_data_delete_semaphore(VALUE self)
{
  semian_cb_data *ptr;
  TypedData_Get_Struct(self, semian_cb_data, &semian_cb_data_type, ptr);
  if (-1 == ptr->semid) // do nothing if semaphore not acquired
    return self;

  if (-1 == semctl(ptr->semid, 0, IPC_RMID)) {
    if (EIDRM == errno) {
      rb_warn("semctl: failed to delete semaphore set with semid %d: already removed", ptr->semid);
      ptr->semid = -1;
    } else {
      rb_warn("semctl: failed to remove semaphore with semid %d, errno %d (%s)",ptr->semid, errno, strerror(errno));
    }
  } else {
    //rb_warn("semctl: semaphore set with semid %d deleted", ptr->semid);
    ptr->semid = -1;
  }
  return self;
}




/*
 * semian_cb_data_lock/unlock and associated functions decrement/increment semaphore
 */

static VALUE
semian_cb_data_lock(VALUE self)
{
  return (VALUE) WITHOUT_GVL(semian_cb_data_lock_without_gvl, (void *)self, RUBY_UBF_IO, NULL);
}

static void *
semian_cb_data_lock_without_gvl(void *self)
{
  semian_cb_data *ptr;
  TypedData_Get_Struct((VALUE)self, semian_cb_data, &semian_cb_data_type, ptr);
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
    rb_raise(eInternal, "error with semop locking,  %d: (%s)", errno, strerror(errno));
    retval=Qfalse;
  } else
    retval=Qtrue;

  ptr->lock_triggered = true;
  //rb_warn("semop: lock success");
  return (void *)retval;
}

static VALUE
semian_cb_data_unlock(VALUE self)
{
  return (VALUE) WITHOUT_GVL(semian_cb_data_unlock_without_gvl, (void *)self, RUBY_UBF_IO, NULL);
}

static void *
semian_cb_data_unlock_without_gvl(void *self)
{
  semian_cb_data *ptr;
  TypedData_Get_Struct((VALUE)self, semian_cb_data, &semian_cb_data_type, ptr);
  if (!(ptr->lock_triggered))
    return (void *)Qtrue;
  if (-1 == ptr->semid){
    rb_raise(eInternal, "semid not set, errno %d: (%s)", errno, strerror(errno));
    return (void *)Qfalse;
  }
  VALUE retval;

  struct timespec ts = { 0 };
  ts.tv_sec = kCBInternalTimeout;

  if (-1 == semtimedop(ptr->semid,&increment,1 , &ts)) {
    rb_raise(eInternal, "error with semop unlocking, errno: %d (%s)", errno, strerror(errno));
    retval=Qfalse;
  } else
    retval=Qtrue;

  ptr->lock_triggered = false;
  //rb_warn("semop unlock success");
  return (void *)retval;
}




/*
  Acquire memory by getting shmid, and then attaching it to a memory location,
    requires semaphore for locking/unlocking to be setup
*/
static VALUE
semian_cb_data_acquire_memory(VALUE self, VALUE permissions)
{
  semian_cb_data *ptr;
  TypedData_Get_Struct(self, semian_cb_data, &semian_cb_data_type, ptr);

  if (-1 == ptr->semid){
    rb_raise(eInternal, "semid not set, errno %d: (%s)", errno, strerror(errno));
    return self;
  }
  if (TYPE(permissions) != T_FIXNUM)
    rb_raise(rb_eTypeError, "expected integer for permissions");

  if (!semian_cb_data_lock(self))
    return self;

  key_t key = ptr->key;
  if (-1 == (ptr->shmid = shmget( key,
                                  2*sizeof(int) + ptr->arr_max_size * sizeof(double),
                                  IPC_CREAT | IPC_EXCL | FIX2LONG(permissions)))) {
    if (errno == EEXIST)
      ptr->shmid = shmget(key, ptr->arr_max_size, IPC_CREAT);
  }
  if (-1 == ptr->shmid) {
    rb_raise(eSyscall, "shmget() failed to acquire a memory shmid with key %d, size %zu, errno %d (%s)", key, ptr->arr_max_size, errno, strerror(errno));
  } else {
    //rb_warn("shmget: successfully got memory id with key %d, shmid %d, size %zu", key, ptr->shmid, ptr->arr_max_size);
  }

  if (0 == ptr->shm_address) {
    ptr->shm_address = shmat(ptr->shmid, (void *)0, 0);
    if (((void*)-1) == ptr->shm_address) {
      rb_raise(eSyscall, "shmat() failed to attach memory with shmid %d, size %zu, errno %d (%s)", ptr->shmid, ptr->arr_max_size, errno, strerror(errno));
      ptr->shm_address = 0;
    } else {
      //rb_warn("shmat: successfully attached shmid %d to %p", ptr->shmid, ptr->shm_address);
      shared_cb_data *data = ptr->shm_address;
      data->successes = 0;
      data->arr_length = 0;
      int i=0;
      for (; i< data->arr_length; ++i)
        data->errors[i]=0;

    }
  }

  semian_cb_data_unlock(self);
  return self;
}

static void
semian_cb_data_delete_memory_inner (semian_cb_data *ptr)
{
  if (0 != ptr->shm_address){
    if (-1 == shmdt(ptr->shm_address)) {
      rb_raise(eSyscall,"shmdt: no attached memory at %p, errno %d (%s)", ptr->shm_address, errno, strerror(errno));
    } else {
      rb_warn("shmdt: successfully detached memory at %p", ptr->shm_address);
    }
    ptr->shm_address = 0;
  }

  if (-1 != ptr->shmid) {
    // Once IPC_RMID is set, no new attaches can be made
    if (-1 == shmctl(ptr->shmid, IPC_RMID, 0)) {
      if (errno == EINVAL) {
        ptr->shmid = -1;
      } {
        rb_raise(eSyscall,"shmctl: error removing memory with shmid %d, errno %d (%s)", ptr->shmid, errno, strerror(errno));
      }
    } else {
      ptr->shmid = -1;
    }
  }
}


static VALUE
semian_cb_data_delete_memory (VALUE self)
{
  semian_cb_data *ptr;
  TypedData_Get_Struct(self, semian_cb_data, &semian_cb_data_type, ptr);

  if (!semian_cb_data_lock(self))
    return self;

  semian_cb_data_delete_memory_inner(ptr);

  semian_cb_data_unlock(self);
  return self;
}





/*
 * Below are methods for successes, semid, shmid, and array pop, push, peek at front and back
 *  and clear, length
 */

static VALUE
semian_cb_data_get_successes(VALUE self)
{
  semian_cb_data *ptr;
  TypedData_Get_Struct(self, semian_cb_data, &semian_cb_data_type, ptr);

  // check shared memory for NULL
  if (0 == ptr->shm_address)
    return Qnil;


  int successes = ptr->shm_address->successes;

  semian_cb_data_unlock(self);
  return INT2NUM(successes);
}

static VALUE
semian_cb_data_set_successes(VALUE self, VALUE num)
{
  semian_cb_data *ptr;
  TypedData_Get_Struct(self, semian_cb_data, &semian_cb_data_type, ptr);

  if (0 == ptr->shm_address)
    return Qnil;

  if (!semian_cb_data_lock(self))
    return Qnil;

  if (TYPE(num) != T_FIXNUM && TYPE(num) != T_FLOAT/*|| TYPE(size) != T_BIGNUM*/)
    return Qnil;

  ptr->shm_address->successes = NUM2INT(num);

  semian_cb_data_unlock(self);
  return num;
}


static VALUE
semian_cb_data_semid(VALUE self)
{
  semian_cb_data *ptr;
  TypedData_Get_Struct(self, semian_cb_data, &semian_cb_data_type, ptr);
  return INT2NUM(ptr->semid);
}
static VALUE
semian_cb_data_shmid(VALUE self)
{
  semian_cb_data *ptr;
  TypedData_Get_Struct(self, semian_cb_data, &semian_cb_data_type, ptr);
  return INT2NUM(ptr->shmid);
}

static VALUE
semian_cb_data_array_at_index(VALUE self, VALUE idx)
{
  semian_cb_data *ptr;
  TypedData_Get_Struct(self, semian_cb_data, &semian_cb_data_type, ptr);

  if (0 == ptr->shm_address)
    return Qnil;

  if (TYPE(idx) != T_FIXNUM && TYPE(idx) != T_FLOAT/*|| TYPE(size) != T_BIGNUM*/)
    return Qnil;

  int index = NUM2INT(idx);

  if (index <0 || index >= ptr->arr_max_size) {
    return Qnil;
  }

  if (!semian_cb_data_lock(self))
    return Qnil;
  shared_cb_data *data = ptr->shm_address;
  VALUE retval = index < (data->arr_length) ? DBL2NUM(data->errors[index]) : Qnil;

  semian_cb_data_unlock(self);
  return retval;

}

static VALUE
semian_cb_data_array_set_index(VALUE self, VALUE idx, VALUE val)
{
  semian_cb_data *ptr;
  TypedData_Get_Struct(self, semian_cb_data, &semian_cb_data_type, ptr);

  // check shared memory for NULL
  if (0 == ptr->shm_address)
    return Qnil;

  if (TYPE(idx) != T_FIXNUM && TYPE(idx) != T_FLOAT/*|| TYPE(size) != T_BIGNUM*/)
    return Qnil;
  if (TYPE(val) != T_FIXNUM && TYPE(val) != T_FLOAT/*|| TYPE(size) != T_BIGNUM*/)
    return Qnil;

  int index = NUM2INT(idx);
  double value = NUM2DBL(val);

  if (index <0 || index >= ptr->arr_max_size) {
    return Qnil;
  }

  if (!semian_cb_data_lock(self)){
    return Qnil;
  }

  ptr->shm_address->errors[index] = value;
  ptr->shm_address->arr_length = index+1;

  semian_cb_data_unlock(self);
  return val;

}

static VALUE
semian_cb_data_array_length(VALUE self)
{
  semian_cb_data *ptr;
  TypedData_Get_Struct(self, semian_cb_data, &semian_cb_data_type, ptr);
  if (0 == ptr->shm_address)
    return Qnil;
  if (!semian_cb_data_lock(self))
    return Qnil;
  int arr_length =ptr->shm_address->arr_length;
  semian_cb_data_unlock(self);
  return INT2NUM(arr_length);
}

static VALUE
semian_cb_data_set_push_back(VALUE self, VALUE num)
{
  semian_cb_data *ptr;
  TypedData_Get_Struct(self, semian_cb_data, &semian_cb_data_type, ptr);
  if (0 == ptr->shm_address)
    return Qnil;
  if (TYPE(num) != T_FIXNUM && TYPE(num) != T_FLOAT/*|| TYPE(size) != T_BIGNUM*/)
    return Qnil;

  if (!semian_cb_data_lock(self))
    return Qnil;

  shared_cb_data *data = ptr->shm_address;
  if (data->arr_length == ptr->arr_max_size) {
    int i;
    for (i=1; i< ptr->arr_max_size; ++i){
      data->errors[i-1] = data->errors[i];
    }
    --(data->arr_length);
  }
  data->errors[(data->arr_length)] = NUM2DBL(num);
  ++(data->arr_length);
  semian_cb_data_unlock(self);
  return self;
}

static VALUE
semian_cb_data_set_pop_back(VALUE self)
{
  semian_cb_data *ptr;
  TypedData_Get_Struct(self, semian_cb_data, &semian_cb_data_type, ptr);
  if (0 == ptr->shm_address)
    return Qnil;

  if (!semian_cb_data_lock(self))
    return Qnil;

  VALUE retval;
  shared_cb_data *data = ptr->shm_address;
  if (0 == data->arr_length)
    retval = Qnil;
  else {
    retval = DBL2NUM(data->errors[data->arr_length-1]);
    --(data->arr_length);
  }

  semian_cb_data_unlock(self);
  return retval;
}

static VALUE
semian_cb_data_set_pop_front(VALUE self)
{
  semian_cb_data *ptr;
  TypedData_Get_Struct(self, semian_cb_data, &semian_cb_data_type, ptr);
  if (0 == ptr->shm_address)
    return Qnil;

  if (!semian_cb_data_lock(self))
    return Qnil;

  VALUE retval;
  shared_cb_data *data = ptr->shm_address;
  if (0 >= data->arr_length)
    retval = Qnil;
  else {
    retval = DBL2NUM(data->errors[0]);
    int i=0;
    for (; i<data->arr_length-1; ++i)
      data->errors[i]=data->errors[i+1];
    --(data->arr_length);
  }

  semian_cb_data_unlock(self);
  return retval;
}

static VALUE
semian_cb_data_set_push_front(VALUE self, VALUE num)
{
  semian_cb_data *ptr;
  TypedData_Get_Struct(self, semian_cb_data, &semian_cb_data_type, ptr);
  if (0 == ptr->shm_address)
    return Qnil;
  if (TYPE(num) != T_FIXNUM && TYPE(num) != T_FLOAT/*|| TYPE(size) != T_BIGNUM*/)
    return Qnil;

  if (!semian_cb_data_lock(self))
    return Qnil;

  double val = NUM2DBL(num);
  shared_cb_data *data = ptr->shm_address;

  int i=data->arr_length;
  for (; i>0; --i)
    data->errors[i]=data->errors[i-1];

  data->errors[0] = val;
  ++(data->arr_length);
  if (data->arr_length>ptr->arr_max_size)
    data->arr_length=ptr->arr_max_size;

  semian_cb_data_unlock(self);
  return self;
}

static VALUE
semian_cb_data_array_clear(VALUE self)
{
  semian_cb_data *ptr;
  TypedData_Get_Struct(self, semian_cb_data, &semian_cb_data_type, ptr);
  if (0 == ptr->shm_address)
    return Qnil;

  if (!semian_cb_data_lock(self))
    return Qnil;
  ptr->shm_address->arr_length=0;

  semian_cb_data_unlock(self);
  return self;
}

static VALUE
semian_cb_data_array_first(VALUE self)
{
  semian_cb_data *ptr;
  TypedData_Get_Struct(self, semian_cb_data, &semian_cb_data_type, ptr);
  if (0 == ptr->shm_address)
    return Qnil;

  if (!semian_cb_data_lock(self))
    return Qnil;

  VALUE retval;
  if (ptr->shm_address->arr_length >=1 && 1 <= ptr->arr_max_size)
    retval = DBL2NUM(ptr->shm_address->errors[0]);
  else
    retval = Qnil;

  semian_cb_data_unlock(self);
  return retval;
}

static VALUE
semian_cb_data_array_last(VALUE self)
{
  semian_cb_data *ptr;
  TypedData_Get_Struct(self, semian_cb_data, &semian_cb_data_type, ptr);
  if (0 == ptr->shm_address)
    return Qnil;

  if (!semian_cb_data_lock(self))
    return Qnil;

  VALUE retval;
  if (ptr->shm_address->arr_length > 0)
    retval = DBL2NUM(ptr->shm_address->errors[ptr->shm_address->arr_length-1]);
  else
    retval = Qnil;

  semian_cb_data_unlock(self);
  return retval;
}

void
Init_semian_cb_data (void) {

  VALUE cSemianModule = rb_const_get(rb_cObject, rb_intern("Semian"));

  VALUE cCircuitBreakerSharedData = rb_const_get(cSemianModule, rb_intern("CircuitBreakerSharedData"));

  rb_define_alloc_func(cCircuitBreakerSharedData, semian_cb_data_alloc);
  rb_define_method(cCircuitBreakerSharedData, "_initialize", semian_cb_data_init, 3);
  rb_define_method(cCircuitBreakerSharedData, "_cleanup", semian_cb_data_clean, 0);
  //rb_define_method(cCircuitBreakerSharedData, "acquire_semaphore", semian_cb_data_acquire_semaphore, 1);
  //rb_define_method(cCircuitBreakerSharedData, "delete_semaphore", semian_cb_data_delete_semaphore, 0);
  //rb_define_method(cCircuitBreakerSharedData, "lock", semian_cb_data_lock, 0);
  //rb_define_method(cCircuitBreakerSharedData, "unlock", semian_cb_data_unlock, 0);
  //rb_define_method(cCircuitBreakerSharedData, "acquire_memory", semian_cb_data_acquire_memory, 1);
  //rb_define_method(cCircuitBreakerSharedData, "delete_memory", semian_cb_data_delete_memory, 0);

  rb_define_method(cCircuitBreakerSharedData, "semid", semian_cb_data_semid, 0);
  rb_define_method(cCircuitBreakerSharedData, "shmid", semian_cb_data_shmid, 0);
  rb_define_method(cCircuitBreakerSharedData, "successes", semian_cb_data_get_successes, 0);
  rb_define_method(cCircuitBreakerSharedData, "successes=", semian_cb_data_set_successes, 1);

  rb_define_method(cCircuitBreakerSharedData, "[]", semian_cb_data_array_at_index, 1);
  rb_define_method(cCircuitBreakerSharedData, "[]=", semian_cb_data_array_set_index, 2);
  rb_define_method(cCircuitBreakerSharedData, "length", semian_cb_data_array_length, 0);
  rb_define_method(cCircuitBreakerSharedData, "size", semian_cb_data_array_length, 0);
  rb_define_method(cCircuitBreakerSharedData, "count", semian_cb_data_array_length, 0);
  rb_define_method(cCircuitBreakerSharedData, "<<", semian_cb_data_set_push_back, 1);
  rb_define_method(cCircuitBreakerSharedData, "push", semian_cb_data_set_push_back, 1);
  rb_define_method(cCircuitBreakerSharedData, "pop", semian_cb_data_set_pop_back, 0);
  rb_define_method(cCircuitBreakerSharedData, "shift", semian_cb_data_set_pop_front, 0);
  rb_define_method(cCircuitBreakerSharedData, "unshift", semian_cb_data_set_push_front, 1);
  rb_define_method(cCircuitBreakerSharedData, "clear", semian_cb_data_array_clear, 0);
  rb_define_method(cCircuitBreakerSharedData, "first", semian_cb_data_array_first, 0);
  rb_define_method(cCircuitBreakerSharedData, "last", semian_cb_data_array_last, 0);

  eInternal = rb_const_get(cSemianModule, rb_intern("InternalError"));
  eSyscall = rb_const_get(cSemianModule, rb_intern("SyscallError"));
  eTimeout = rb_const_get(cSemianModule, rb_intern("TimeoutError"));

  decrement.sem_num = kCBIndexTicketLock;
  decrement.sem_op = -1;
  decrement.sem_flg = SEM_UNDO;

  increment.sem_num = kCBIndexTicketLock;
  increment.sem_op = 1;
  increment.sem_flg = SEM_UNDO;

  struct seminfo info_buf;

  if (semctl(0, 0, SEM_INFO, &info_buf) == -1) {
    rb_raise(eInternal, "unable to determine maximum semaphore count - semctl() returned %d: %s ", errno, strerror(errno));
  }
  system_max_semaphore_count = info_buf.semvmx;

  /* Maximum number of tickets available on this system. */
  rb_const_get(cSemianModule, rb_intern("MAX_TICKETS"));
}
