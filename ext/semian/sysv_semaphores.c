#include "sysv_semaphores.h"

static void *
acquire_semaphore(void *p);

// Generate string rep for sem indices for debugging puproses
static const char *SEMINDEX_STRING[] = {
    FOREACH_SEMINDEX(GENERATE_STRING)
};

void
raise_semian_syscall_error(const char *syscall, int error_num)
{
  rb_raise(eSyscall, "%s failed, errno: %d (%s)", syscall, error_num, strerror(error_num));
}

key_t
generate_key(const char *name)
{
  char semset_size_key[20];
  char *uniq_id_str;

  // It is necessary for the cardinatily of the semaphore set to be part of the key
  // or else sem_get will complain that we have requested an incorrect number of sems
  // for the desired key, and have changed the number of semaphores for a given key
  sprintf(semset_size_key, "_NUM_SEMS_%d", SI_NUM_SEMAPHORES);
  uniq_id_str = malloc(strlen(name)+strlen(semset_size_key)+1);
  strcpy(uniq_id_str, name);
  strcat(uniq_id_str, semset_size_key);

  union {
    unsigned char str[SHA_DIGEST_LENGTH];
    key_t key;
  } digest;
  SHA1((const unsigned char *) uniq_id_str, strlen(uniq_id_str), digest.str);
  free(uniq_id_str);
  /* TODO: compile-time assertion that sizeof(key_t) > SHA_DIGEST_LENGTH */
  return digest.key;
}

void
set_semaphore_permissions(int sem_id, long permissions)
{
  union semun sem_opts;
  struct semid_ds stat_buf;

  sem_opts.buf = &stat_buf;
  semctl(sem_id, 0, IPC_STAT, sem_opts);
  if ((stat_buf.sem_perm.mode & 0xfff) != permissions) {
    stat_buf.sem_perm.mode &= ~0xfff;
    stat_buf.sem_perm.mode |= permissions;
    semctl(sem_id, 0, IPC_SET, sem_opts);
  }
}

int
create_semaphore(int key, long permissions, int *created)
{
  int semid = 0;
  int flags = 0;

  *created = 0;
  flags = IPC_EXCL | IPC_CREAT | permissions;

  semid = semget(key, SI_NUM_SEMAPHORES, flags);
  if (semid >= 0) {
    *created = 1;
  } else if (semid == -1 && errno == EEXIST) {
    flags &= ~IPC_EXCL;
    semid = semget(key, SI_NUM_SEMAPHORES, flags);
  }
  return semid;
}


int
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

int
get_sem_val(int sem_id, int sem_index)
{
  int ret = semctl(sem_id, sem_index, GETVAL);
  if (ret == -1) {
    rb_raise(eInternal, "error getting value of %s, errno: %d (%s)", SEMINDEX_STRING[sem_index], errno, strerror(errno));
  }
  return ret;
}

void
sem_meta_lock(int sem_id)
{
  struct timespec ts = { 0 };
  ts.tv_sec = INTERNAL_TIMEOUT;

  if (perform_semop(sem_id, SI_SEM_LOCK, -1, SEM_UNDO, &ts) == -1) {
    raise_semian_syscall_error("error acquiring internal semaphore lock, semtimedop()", errno);
  }
}

void
sem_meta_unlock(int sem_id)
{
  if (perform_semop(sem_id, SI_SEM_LOCK, 1, SEM_UNDO, NULL) == -1) {
    raise_semian_syscall_error("error releasing internal semaphore lock, semop()", errno);
  }
}

int
get_semaphore(int key)
{
  return semget(key, SI_NUM_SEMAPHORES, 0);
}

void *
acquire_semaphore_without_gvl(void *p)
{
  WITHOUT_GVL(acquire_semaphore, p, RUBY_UBF_IO, NULL);
  return NULL;
}

static void *
acquire_semaphore(void *p)
{
  semian_resource_t *res = (semian_resource_t *) p;
  res->error = 0;
  if (perform_semop(res->sem_id, SI_SEM_TICKETS, -1, SEM_UNDO, &res->timeout) == -1) {
    res->error = errno;
  }
  return NULL;
}
