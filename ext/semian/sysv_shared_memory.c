#include "sysv_shared_memory.h"

#include "util.h"

void*
get_or_create_shared_memory(uint64_t key)
{
  void* shmem = NULL;
  if (!key) return NULL;

  dprintf("Creating shared memory (key: %lu)", key);
  int shmid = shmget(key, SHM_DEFAULT_SIZE, IPC_CREAT | IPC_EXCL | SHM_DEFAULT_PERMISSIONS);
  if (shmid != -1) {
    dprintf("Created shared memory (key:%lu sem_id:%d)", key, shmid);
    shmem = shmat(shmid, NULL, 0);
    if (shmem == (void*)-1) {
      rb_raise(rb_eArgError, "could not get shared memory (%s)", strerror(errno));
    }

    shmctl(key, IPC_RMID, NULL);
  } else {
    shmid = shmget(key, SHM_DEFAULT_SIZE, SHM_DEFAULT_PERMISSIONS);
    if (shmid == -1) {
      rb_raise(rb_eArgError, "could not get shared memory (%s)", strerror(errno));
    }

    dprintf("Got shared memory (key:%lu sem_id:%d)", key, shmid);
    shmem = shmat(shmid, NULL, 0);
    if (shmem == (void*)-1) {
      rb_raise(rb_eArgError, "could not get shared memory (%s)", strerror(errno));
    }
  }

  return shmem;
}

void
free_shared_memory(void* shmem)
{
  if (!shmem) return;
  shmdt(shmem);
}
