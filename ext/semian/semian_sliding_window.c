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

#include <math.h>

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
  int counter;
  int window_length;
  long window[];
} shared_cb_data;

typedef struct {
  //semaphore, shared memory data and pointer
  key_t key;
  size_t max_window_length;
  bool lock_triggered;
  int semid;
  int shmid;
  shared_cb_data *shm_address;
} semian_cb_data;

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
static VALUE semian_cb_data_destroy(VALUE self);
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
static VALUE semian_cb_data_get_counter(VALUE self);
static VALUE semian_cb_data_set_counter(VALUE self, VALUE num);
static VALUE semian_cb_data_semid(VALUE self);
static VALUE semian_cb_data_shmid(VALUE self);
static VALUE semian_cb_data_array_length(VALUE self);
static VALUE semian_cb_data_set_push_back(VALUE self, VALUE num);
static VALUE semian_cb_data_set_pop_back(VALUE self);
static VALUE semian_cb_data_set_push_front(VALUE self, VALUE num);
static VALUE semian_cb_data_set_pop_front(VALUE self);

static VALUE semian_cb_data_is_shared(VALUE self);


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
    rb_raise(rb_eTypeError, "expected integer for max_window_length");
  if (TYPE(permissions) != T_FIXNUM)
    rb_raise(rb_eTypeError, "expected integer for permissions");

  if (NUM2SIZET(size) <= 0)
    rb_raise(rb_eArgError, "max_window_length must be larger than 0");

  const char *id_str = NULL;
  if (TYPE(id) == T_SYMBOL) {
    id_str = rb_id2name(rb_to_id(id));
  } else if (TYPE(id) == T_STRING) {
    id_str = RSTRING_PTR(id);
  }
  ptr->key = generate_key(id_str);
  //rb_warn("converted name %s to key %d", id_str, ptr->key);

  // Guarantee max_window_length >=1 or error thrown
  ptr->max_window_length = NUM2SIZET(size);

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
semian_cb_data_destroy(VALUE self)
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
    rb_raise(eInternal, "error acquiring semaphore lock to mutate circuit breaker structure, %d: (%s)", errno, strerror(errno));
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
    rb_raise(eInternal, "error unlocking semaphore, %d (%s)", errno, strerror(errno));
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
    return Qfalse;

  int created = 0;
  key_t key = ptr->key;
  int byte_size = 2*sizeof(int) + ptr->max_window_length * sizeof(long);
  int flags = IPC_CREAT | IPC_EXCL | FIX2LONG(permissions);

  if (-1 == (ptr->shmid = shmget( key, byte_size, flags))) {
    if (errno == EEXIST) {
      ptr->shmid = shmget(key, byte_size, flags & ~IPC_EXCL);
    }
  } else
    created = 1;

  struct shared_cb_data *old_data=NULL;
  int old_size = 0;

  if (-1 == ptr->shmid) {
    if (errno == EINVAL) {
      // EINVAL is either because
      // 1. segment with key exists but size given >= size of segment
      // 2. segment was requested to be created, but (size > SHMMAX || size < SHMMIN)

      // Unlikely for 2 to occur, but we check by requesting a memory of size 1 byte
      // We handle 1 by marking the old memory and shmid as IPC_RMID, not writing to it again,
      //  copying as much data over to the new memory

      // Changing memory size requires restarting semian with new args for initialization

      int shmid = shmget(key, 1, flags & ~IPC_EXCL);
      if (-1 != shmid) {
        struct shared_cb_data *data = shmat(shmid, (void *)0, 0);
        if ((void *)-1 != data) {
          struct shmid_ds shm_info;
          if (-1 != shmctl(shmid, IPC_STAT, &shm_info)) {
            old_size = shm_info.shm_segsz;
            if (byte_size != old_size) {
              old_data = malloc(shm_info.shm_segsz);
              memcpy(old_data,data,fmin(old_size, byte_size));
              ptr->shmid = shmid;
              ptr->shm_address = (shared_cb_data *)data;
              semian_cb_data_delete_memory_inner(ptr);
            }

            // Flagging for deletion sets a shm's associated key to be 0 so shmget gets a different shmid.
            if (-1 != (ptr->shmid = shmget(key, byte_size, flags))) {
              created = 1;
            }
          }
        }
      }
    }

    if (-1 == ptr->shmid && errno == EINVAL) {
      if (old_data)
        free(old_data);
      semian_cb_data_unlock(self);
      rb_raise(eSyscall, "shmget() failed to acquire a memory shmid with key %d, size %zu, errno %d (%s)", key, ptr->max_window_length, errno, strerror(errno));
    }
  }

  if (0 == ptr->shm_address) {
    ptr->shm_address = shmat(ptr->shmid, (void *)0, 0);
    if (((void*)-1) == ptr->shm_address) {
      semian_cb_data_unlock(self);
      ptr->shm_address = 0;
      if (old_data)
        free(old_data);
      rb_raise(eSyscall, "shmat() failed to attach memory with shmid %d, size %zu, errno %d (%s)", ptr->shmid, ptr->max_window_length, errno, strerror(errno));
    } else {
      if (created) {
        if (old_data) {
          // transfer data over
          memcpy(ptr->shm_address,old_data,fmin(old_size, byte_size));

          ptr->shm_address->window_length = fmin(ptr->max_window_length-1, ptr->shm_address->window_length);
        } else {
          shared_cb_data *data = ptr->shm_address;
          data->counter = 0;
          data->window_length = 0;
          for (int i=0; i< data->window_length; ++i)
            data->window[i]=0;
        }
      }
    }
  }
  if (old_data)
    free(old_data);
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
    }
    ptr->shm_address = 0;
  }

  if (-1 != ptr->shmid) {
    // Once IPC_RMID is set, no new attaches can be made
    if (-1 == shmctl(ptr->shmid, IPC_RMID, 0)) {
      if (errno == EINVAL) {
        ptr->shmid = -1;
      } {
        rb_raise(eSyscall,"shmctl: error flagging memory for removal with shmid %d, errno %d (%s)", ptr->shmid, errno, strerror(errno));
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
 * Below are methods for counter, semid, shmid, and array pop, push, peek at front and back
 *  and clear, length
 */

static VALUE
semian_cb_data_get_counter(VALUE self)
{
  semian_cb_data *ptr;
  TypedData_Get_Struct(self, semian_cb_data, &semian_cb_data_type, ptr);

  // check shared memory for NULL
  if (0 == ptr->shm_address)
    return Qnil;

  if (!semian_cb_data_lock(self))
    return Qnil;

  int counter = ptr->shm_address->counter;

  semian_cb_data_unlock(self);
  return INT2NUM(counter);
}

static VALUE
semian_cb_data_set_counter(VALUE self, VALUE num)
{
  semian_cb_data *ptr;
  TypedData_Get_Struct(self, semian_cb_data, &semian_cb_data_type, ptr);

  if (0 == ptr->shm_address)
    return Qnil;

  if (TYPE(num) != T_FIXNUM && TYPE(num) != T_FLOAT)
    return Qnil;

  if (!semian_cb_data_lock(self))
    return Qnil;

  ptr->shm_address->counter = NUM2INT(num);

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
semian_cb_data_array_length(VALUE self)
{
  semian_cb_data *ptr;
  TypedData_Get_Struct(self, semian_cb_data, &semian_cb_data_type, ptr);
  if (0 == ptr->shm_address)
    return Qnil;
  if (!semian_cb_data_lock(self))
    return Qnil;
  int window_length =ptr->shm_address->window_length;
  semian_cb_data_unlock(self);
  return INT2NUM(window_length);
}

static VALUE
semian_cb_data_set_push_back(VALUE self, VALUE num)
{
  semian_cb_data *ptr;
  TypedData_Get_Struct(self, semian_cb_data, &semian_cb_data_type, ptr);
  if (0 == ptr->shm_address)
    return Qnil;
  if (TYPE(num) != T_FIXNUM && TYPE(num) != T_FLOAT && TYPE(num) != T_BIGNUM)
    return Qnil;

  if (!semian_cb_data_lock(self))
    return Qnil;

  shared_cb_data *data = ptr->shm_address;
  if (data->window_length == ptr->max_window_length) {
    for (int i=1; i< ptr->max_window_length; ++i){
      data->window[i-1] = data->window[i];
    }
    --(data->window_length);
  }
  data->window[(data->window_length)] = NUM2LONG(num);
  ++(data->window_length);
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
  if (0 == data->window_length)
    retval = Qnil;
  else {
    retval = LONG2NUM(data->window[data->window_length-1]);
    --(data->window_length);
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
  if (0 >= data->window_length)
    retval = Qnil;
  else {
    retval = LONG2NUM(data->window[0]);
    for (int i=0; i<data->window_length-1; ++i)
      data->window[i]=data->window[i+1];
    --(data->window_length);
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
  if (TYPE(num) != T_FIXNUM && TYPE(num) != T_FLOAT && TYPE(num) != T_BIGNUM)
    return Qnil;

  if (!semian_cb_data_lock(self))
    return Qnil;

  long val = NUM2LONG(num);
  shared_cb_data *data = ptr->shm_address;

  int i=data->window_length;
  for (; i>0; --i)
    data->window[i]=data->window[i-1];

  data->window[0] = val;
  ++(data->window_length);
  if (data->window_length>ptr->max_window_length)
    data->window_length=ptr->max_window_length;

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
  ptr->shm_address->window_length=0;

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
  if (ptr->shm_address->window_length >=1)
    retval = LONG2NUM(ptr->shm_address->window[0]);
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
  if (ptr->shm_address->window_length > 0)
    retval = LONG2NUM(ptr->shm_address->window[ptr->shm_address->window_length-1]);
  else
    retval = Qnil;

  semian_cb_data_unlock(self);
  return retval;
}

static VALUE
semian_cb_data_is_shared(VALUE self)
{
  return Qtrue;
}

void
Init_semian_cb_data (void) {

  VALUE cSemianModule = rb_const_get(rb_cObject, rb_intern("Semian"));

  VALUE cCircuitBreakerSharedData = rb_const_get(cSemianModule, rb_intern("SlidingWindow"));

  rb_define_alloc_func(cCircuitBreakerSharedData, semian_cb_data_alloc);
  rb_define_method(cCircuitBreakerSharedData, "_initialize", semian_cb_data_init, 3);
  rb_define_method(cCircuitBreakerSharedData, "_destroy", semian_cb_data_destroy, 0);
  //rb_define_method(cCircuitBreakerSharedData, "acquire_semaphore", semian_cb_data_acquire_semaphore, 1);
  //rb_define_method(cCircuitBreakerSharedData, "delete_semaphore", semian_cb_data_delete_semaphore, 0);
  //rb_define_method(cCircuitBreakerSharedData, "lock", semian_cb_data_lock, 0);
  //rb_define_method(cCircuitBreakerSharedData, "unlock", semian_cb_data_unlock, 0);
  //rb_define_method(cCircuitBreakerSharedData, "acquire_memory", semian_cb_data_acquire_memory, 1);
  //rb_define_method(cCircuitBreakerSharedData, "delete_memory", semian_cb_data_delete_memory, 0);

  rb_define_method(cCircuitBreakerSharedData, "semid", semian_cb_data_semid, 0);
  rb_define_method(cCircuitBreakerSharedData, "shmid", semian_cb_data_shmid, 0);
  rb_define_method(cCircuitBreakerSharedData, "successes", semian_cb_data_get_counter, 0);
  rb_define_method(cCircuitBreakerSharedData, "successes=", semian_cb_data_set_counter, 1);

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

  rb_define_singleton_method(cCircuitBreakerSharedData, "shared?", semian_cb_data_is_shared, 0);

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
