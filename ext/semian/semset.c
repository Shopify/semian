#include <semset.h>

const char *SEMINDEX_STRING[] = {
    FOREACH_SEMINDEX(GENERATE_STRING)
};

void
raise_semian_syscall_error(const char *syscall, int error_num)
{
  rb_raise(eSyscall, "%s failed, errno: %d (%s)", syscall, error_num, strerror(error_num));
}

key_t
generate_sem_set_key(const char *name)
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
