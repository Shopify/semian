/*
For manipulating the semian's semaphore set

Semian semaphore operations and initialization,
and functions associated directly weth semops.
*/
#ifndef SEMIAN_SEMSET_H
#define SEMIAN_SEMSET_H

#include <semian.h>

// Defines for ruby threading primitives
#if defined(HAVE_RB_THREAD_CALL_WITHOUT_GVL) && defined(HAVE_RUBY_THREAD_H)
// 2.0
#include <ruby/thread.h>
#define WITHOUT_GVL(fn,a,ubf,b) rb_thread_call_without_gvl((fn),(a),(ubf),(b))
#elif defined(HAVE_RB_THREAD_BLOCKING_REGION)
 // 1.9
typedef VALUE (*my_blocking_fn_t)(void*);
#define WITHOUT_GVL(fn,a,ubf,b) rb_thread_blocking_region((my_blocking_fn_t)(fn),(a),(ubf),(b))
#endif

// Time to wait for timed ops to complete
#define INTERNAL_TIMEOUT 5 // seconds

VALUE eSyscall, eTimeout, eInternal;

// Here we define an enum value and string representation of each semaphore
// This allows us to key the sem value and string rep in sync easily
// utilizing pre-processor macros.
//   SI_SEM_TICKETS             semaphore for the tickets currently issued
//   SI_SEM_CONFIGURED_TICKETS  semaphore to track the desired number of tickets available for issue
//   SI_SEM_LOCK                metadata lock to act as a mutex, ensuring thread-safety for updating other semaphores
//   SI_NUM_SEMAPHORES          always leave this as last entry for count to be accurate
#define FOREACH_SEMINDEX(SEMINDEX) \
        SEMINDEX(SI_SEM_TICKETS)   \
        SEMINDEX(SI_SEM_CONFIGURED_TICKETS)  \
        SEMINDEX(SI_SEM_LOCK)   \
        SEMINDEX(SI_NUM_SEMAPHORES)  \

#define GENERATE_ENUM(ENUM) ENUM,
#define GENERATE_STRING(STRING) #STRING,

// Generate enum for sem indices
enum SEMINDEX_ENUM {
    FOREACH_SEMINDEX(GENERATE_ENUM)
};

// Generate string rep for sem indices for debugging puproses
extern const char *SEMINDEX_STRING[];

// Helper for syscall verbose debugging
void
raise_semian_syscall_error(const char *syscall, int error_num);

// Genurates a unique key for the semaphore from the resource id
key_t
generate_sem_set_key(const char *name);

// Set semaphore UNIX octal permissions
void
set_semaphore_permissions(int sem_id, long permissions);

// Create a new sysV IPC semaphore set
int
create_semaphore(int key, long permissions, int *created);

// Wrapper to performs a semop call
// The call may be timed or untimed
static inline int
perform_semop(int sem_id, short index, short op, short flags, struct timespec *ts)
{
  struct sembuf buf = { 0 };

  buf.sem_num = index;
  buf.sem_op  = op;
  buf.sem_flg = flags;

  if (ts) {
    return semtimedop(sem_id, &buf, 1, ts);
  } else {
    return semop(sem_id, &buf, 1);
  }
}

// Retrieve the current number of tickets in a semaphore by its semaphore index
static inline int
get_sem_val(int sem_id, int sem_index)
{
  int ret = semctl(sem_id, sem_index, GETVAL);
  if (ret == -1) {
    rb_raise(eInternal, "error getting value of %s, errno: %d (%s)", SEMINDEX_STRING[sem_index], errno, strerror(errno));
  }
  return ret;
}

// Obtain an exclusive lock on the semaphore set critical section
static inline void
sem_meta_lock(int sem_id)
{
  struct timespec ts = { 0 };
  ts.tv_sec = INTERNAL_TIMEOUT;

  if (perform_semop(sem_id, SI_SEM_LOCK, -1, SEM_UNDO, &ts) == -1) {
    raise_semian_syscall_error("error acquiring internal semaphore lock, semtimedop()", errno);
  }
}

// Release an exclusive lock on the semaphore set critical section
static inline void
sem_meta_unlock(int sem_id)
{
  if (perform_semop(sem_id, SI_SEM_LOCK, 1, SEM_UNDO, NULL) == -1) {
    raise_semian_syscall_error("error releasing internal semaphore lock, semop()", errno);
  }
}

// Retrieve a semaphore's ID from its key
static inline int
get_semaphore(int key)
{
  return semget(key, SI_NUM_SEMAPHORES, 0);
}

// WARNING: Never call directly
// Decrements the ticket semaphore within the semaphore set
static inline void *
acquire_semaphore(void *p)
{
  semian_resource_t *res = (semian_resource_t *) p;
  res->error = 0;
  if (perform_semop(res->sem_id, SI_SEM_TICKETS, -1, SEM_UNDO, &res->timeout) == -1) {
    res->error = errno;
  }
  return NULL;
}

// Acquire a ticket with the ruby Global VM lock released
static inline void *
acquire_semaphore_without_gvl(void *p)
{
  WITHOUT_GVL(acquire_semaphore, p, RUBY_UBF_IO, NULL);
  return NULL;
}
#endif // SEMIAN_SEMSET_H
