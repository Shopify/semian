#ifndef EXT_SEMIAN_SYSV_SHARED_MEMORY_H
#define EXT_SEMIAN_SYSV_SHARED_MEMORY_H

#include <errno.h>
#include <stdint.h>
#include <sys/ipc.h>
#include <sys/shm.h>

// Default permissions for shared memory
#define SHM_DEFAULT_PERMISSIONS 0660
#define SHM_DEFAULT_SIZE 4096

void*
get_or_create_shared_memory(uint64_t key);

void
free_shared_memory(void* key);

#endif // EXT_SEMIAN_SYSV_SHARED_MEMORY_H
