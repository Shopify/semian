/*
For manipulating the semian's semaphore set

Semian semaphore operations and initialization,
and functions associated directly weth semops.
*/
#ifndef SEMIAN_SEMSET_H
#define SEMIAN_SEMSET_H

// Time to wait for timed ops to complete
#define INTERNAL_TIMEOUT 5 // seconds

#include <semian.h>

VALUE eSyscall, eTimeout, eInternal;

// Helper for syscall verbose debugging
void
raise_semian_syscall_error(const char *syscall, int error_num);

// Genurates a unique key for the semaphore from the resource id
key_t
generate_key(const char *name);

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
get_max_tickets(int sem_id);

// Retrieve a semaphore's ID from its key
int
get_semaphore(int key);

// Decrements the ticket semaphore within the semaphore set
void *
acquire_semaphore_without_gvl(void *p);

#endif // SEMIAN_SEMSET_H
