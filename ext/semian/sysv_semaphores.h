/*
For manipulating the semian's semaphore set

Semian semaphore operations and initialization,
and functions associated directly weth semops.
*/
#ifndef SEMIAN_SEMSET_H
#define SEMIAN_SEMSET_H

#include <openssl/sha.h>

#include <ruby.h>
#include <ruby/util.h>
#include <ruby/io.h>

#include "types.h"

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

// FIXME: These declarations will be modified in a subsequent PR
// temporarily placed here while refactoring.
// will be heavily modified when semian_sysv_semaphores.c is created

key_t
generate_sem_set_key(const char *name);

void
set_semaphore_permissions(int sem_id, long permissions);

int
create_semaphore(int key, long permissions, int *created);

int
get_semaphore(int key);

void
raise_semian_syscall_error(const char *syscall, int error_num);

int
perform_semop(int sem_id, short index, short op, short flags, struct timespec *ts);

void *
acquire_semaphore_without_gvl(void *p);

#endif // SEMIAN_SEMSET_H
