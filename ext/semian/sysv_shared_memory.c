#include "sysv_shared_memory.h"

#include "util.h"

#define TIMEOUT_MS (5 * 1e6)
#define WAIT_MS (10)
#define RETRIES (TIMEOUT_MS / WAIT_MS)

void*
wait_for_shared_memory(uint64_t key)
{
  for (int i = 0; i < RETRIES; ++i) {
    int shmid = shmget(key, SHM_DEFAULT_SIZE, SHM_DEFAULT_PERMISSIONS);
    if (shmid != -1) {
      return shmat(shmid, NULL, 0);
    }
    usleep(WAIT_MS);
  }

  rb_raise(rb_eArgError, "could not get shared memory");
}

void*
get_or_create_shared_memory(uint64_t key, shared_memory_init_fn fn)
{
  void* shmem = NULL;
  if (!key) return NULL;

  dprintf("Creating shared memory (key: %lu)", key);
  int shmid = shmget(key, SHM_DEFAULT_SIZE, IPC_CREAT | IPC_EXCL | SHM_DEFAULT_PERMISSIONS);
  if (shmid != -1) {
    dprintf("Created shared memory (key: %lu)", key);

    shmem = shmat(shmid, NULL, 0);
    if (shmem == (void*)-1) {
      rb_raise(rb_eArgError, "could not get shared memory (%s)", strerror(errno));
    }

    if (fn) fn(shmem);

    shmctl(key, IPC_RMID, NULL);
  } else {
    shmem = wait_for_shared_memory(key);
  }

  return shmem;
}

void
free_shared_memory(void* shmem)
{
  if (!shmem) return;
  shmdt(shmem);
}
