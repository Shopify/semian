/*
For managing SysV shared memory segments for cross-process state sharing.
*/
#ifndef SEMIAN_SYSV_SHARED_MEMORY_H
#define SEMIAN_SYSV_SHARED_MEMORY_H

#include <sys/ipc.h>
#include <sys/shm.h>
#include <errno.h>
#include <string.h>

#include <ruby.h>

#define SHM_DEFAULT_PERMISSIONS 0660
#define SHM_DEFAULT_SIZE 4096

// Create or attach to a SysV shared memory segment
// Returns shm_id on success, -1 on failure
int
create_or_attach_shared_memory(key_t key, size_t size, int *created);

// Attach a shared memory segment to the process's address space
// Returns pointer to memory on success, (void *)-1 on failure
void *
attach_shared_memory(int shm_id);

// Detach a shared memory segment from the process
// Returns 0 on success, -1 on failure
int
detach_shared_memory(void *addr);

// Destroy a shared memory segment (marks for deletion)
// Returns 0 on success, -1 on failure
int
destroy_shared_memory(int shm_id);

#endif // SEMIAN_SYSV_SHARED_MEMORY_H

