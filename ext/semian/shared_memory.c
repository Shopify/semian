#include "shared_memory.h"
#include "sysv_semaphores.h"

int
create_or_attach_shared_memory(key_t key, size_t size, int *created)
{
  int shm_id;

  if (created) {
    *created = 0;
  }

  // Create new segment, fail if it exists
  shm_id = shmget(key, size, IPC_CREAT | IPC_EXCL | SHM_DEFAULT_PERMISSIONS);

  if (shm_id != -1) {
    if (created) {
      *created = 1;
    }
    return shm_id;
  }

  // Check if memory segment already exists
  if (errno == EEXIST) {
    // Get existing segment
    shm_id = shmget(key, size, SHM_DEFAULT_PERMISSIONS);
    if (shm_id == -1) { // Error (e.g., size or permission mismatch, segment was deleted before we could attach)
      return -1;
    }
    return shm_id;
  }

  return -1;
}

void *
attach_shared_memory(int shm_id)
{
  return shmat(shm_id, NULL, 0);
}

int
detach_shared_memory(void *addr)
{
  return shmdt(addr);
}

int
destroy_shared_memory(int shm_id)
{
  int result;

  result = shmctl(shm_id, IPC_RMID, NULL);

  if (result == -1 && (errno == EINVAL || errno == EIDRM)) {
    return 0;
  }

  return result;
}

