#ifndef EXT_SEMIAN_SYSV_SHARED_MEMORY_H
#define EXT_SEMIAN_SYSV_SHARED_MEMORY_H

#include <errno.h>
#include <stdint.h>
#include <sys/ipc.h>
#include <sys/shm.h>

// Default permissions for shared memory
#define SHM_DEFAULT_PERMISSIONS 0660
#define SHM_DEFAULT_SIZE 1024

typedef void (*shared_memory_init_fn)(void*);

void*
get_or_create_shared_memory(uint64_t key, shared_memory_init_fn fn);

void
free_shared_memory(void* key);

#endif // EXT_SEMIAN_SYSV_SHARED_MEMORY_H
