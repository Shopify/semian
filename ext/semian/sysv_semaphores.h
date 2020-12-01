/*
For manipulating the semian's semaphore set

Semian semaphore operations and initialization,
and functions associated directly weth semops.
*/
#ifndef SEMIAN_SEMSET_H
#define SEMIAN_SEMSET_H

#include <errno.h>
#include <stdio.h>
#include <string.h>

#include <openssl/sha.h>
#include <ruby.h>
#include <ruby/util.h>
#include <ruby/io.h>

#include "types.h"
#include "tickets.h"

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
#define INTERNAL_TIMEOUT 5 /* seconds */

// Time to wait while checking if semaphore has been initialized
#define INIT_WAIT 10 /* microseconds */

// Helper definition to prevent magic number for conversion of microseconds to seconds
#define MICROSECONDS_IN_SECOND 1000000

// Here we define an enum value and string representation of each semaphore
// This allows us to key the sem value and string rep in sync easily
// utilizing pre-processor macros.
// If you're unfamiliar with this pattern, this is using "x macros"
//   SI_SEM_LOCK                metadata lock to act as a mutex, ensuring thread-safety for updating other semaphores
//   SI_SEM_TICKETS             semaphore for the tickets currently issued
//   SI_SEM_CONFIGURED_TICKETS  semaphore to track the desired number of tickets available for issue
//   SI_SEM_REGISTERED_WORKERS  semaphore for the number of workers currently registered
//   SI_NUM_SEMAPHORES          always leave this as last entry for count to be accurate
#define FOREACH_SEMINDEX(SEMINDEX) \
        SEMINDEX(SI_SEM_LOCK)   \
        SEMINDEX(SI_SEM_TICKETS)   \
        SEMINDEX(SI_SEM_CONFIGURED_TICKETS)  \
        SEMINDEX(SI_SEM_REGISTERED_WORKERS)  \
        SEMINDEX(SI_NUM_SEMAPHORES)  \

#define GENERATE_ENUM(ENUM) ENUM,
#define GENERATE_STRING(STRING) #STRING,

// Generate enum for sem indices
enum SEMINDEX_ENUM {
    FOREACH_SEMINDEX(GENERATE_ENUM)
};

extern VALUE eSyscall, eTimeout, eInternal;

// Helper for syscall verbose debugging
void
raise_semian_syscall_error(const char *syscall, int error_num);

// Initialize the sysv semaphore structure
void
initialize_semaphore_set(semian_resource_t* res, const char* id_str, long permissions, int tickets, double quota, int is_global);

// Set semaphore UNIX octal permissions
void
set_semaphore_permissions(int sem_id, long permissions);

// Create a new sysV IPC semaphore set
int
create_semaphore(int key, long permissions, int *created);

// Wrapper to performs a semop call
// The call may be timed or untimed
int
perform_semop(int sem_id, short index, short op, short flags, struct timespec *ts);

// Retrieve the current number of tickets in a semaphore by its semaphore index
int
get_sem_val(int sem_id, int sem_index);

// Obtain an exclusive lock on the semaphore set critical section
void
sem_meta_lock(int sem_id);

// Release an exclusive lock on the semaphore set critical section
void
sem_meta_unlock(int sem_id);

// Retrieve a semaphore's ID from its key
int
get_semaphore(int key);

// Decrements the ticket semaphore within the semaphore set
void *
acquire_semaphore_without_gvl(void *p);

#ifdef DEBUG
static inline void
print_sem_vals(int sem_id)
{
  printf("lock %d, tickets: %d configured: %d, registered workers %d\n",
   get_sem_val(sem_id, SI_SEM_LOCK),
   get_sem_val(sem_id, SI_SEM_TICKETS),
   get_sem_val(sem_id, SI_SEM_CONFIGURED_TICKETS),
   get_sem_val(sem_id, SI_SEM_REGISTERED_WORKERS)
  );
}
#endif

#endif // SEMIAN_SEMSET_H
