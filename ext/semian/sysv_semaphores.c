#include "sysv_semaphores.h"

static key_t
generate_key(const char *name);

static void *
acquire_semaphore(void *p);

static int
wait_for_new_semaphore_set(key_t key, long permissions);

static void
initialize_new_semaphore_values(int sem_id, long permissions);

// Generate string rep for sem indices for debugging puproses
static const char *SEMINDEX_STRING[] = {
    FOREACH_SEMINDEX(GENERATE_STRING)
};

void
raise_semian_syscall_error(const char *syscall, int error_num)
{
  rb_raise(eSyscall, "%s failed, errno: %d (%s)", syscall, error_num, strerror(error_num));
}

void
initialize_semaphore_set(semian_resource_t* res, const char* id_str, long permissions, int tickets, double quota)
{

  res->key = generate_key(id_str);
  res->strkey = (char*)  malloc((2 /*for 0x*/+ sizeof(uint64_t) /*actual key*/+ 1 /*null*/) * sizeof(char));
  sprintf(res->strkey, "0x%08x", (unsigned int) res->key);
  res->sem_id = semget(res->key, SI_NUM_SEMAPHORES, IPC_CREAT | IPC_EXCL | permissions);

  /*
  This approach is based on http://man7.org/tlpi/code/online/dist/svsem/svsem_good_init.c.html
  which avoids race conditions when initializing semaphore sets.
  */
  if (res->sem_id != -1) {
    // Happy path - we are the first worker, initialize the semaphore set.
    initialize_new_semaphore_values(res->sem_id, permissions);
  } else {
    // Something went wrong
    if (errno != EEXIST) {
      raise_semian_syscall_error("semget() failed to initialize semaphore values", errno);
    } else {
      // The semaphore set already exists, ensure it is initialized
      res->sem_id = wait_for_new_semaphore_set(res->key, permissions);
    }
  }

  set_semaphore_permissions(res->sem_id, permissions);

  /*
    Ensure that a worker for this process is registered.
    Note that from ruby we ensure that at most one worker may be registered per process.
  */
  if (perform_semop(res->sem_id, SI_SEM_REGISTERED_WORKERS, 1, SEM_UNDO, NULL) == -1) {
    rb_raise(eInternal, "error incrementing registered workers, errno: %d (%s)", errno, strerror(errno));
  }

  sem_meta_lock(res->sem_id); // Sets otime for the first time by acquiring the sem lock
  configure_tickets(res->sem_id, tickets,  quota);
  sem_meta_unlock(res->sem_id);
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
    rb_raise(eInternal, "error getting value of %s for sem %d, errno: %d (%s)", SEMINDEX_STRING[sem_index], sem_id, errno, strerror(errno));
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
#ifdef DEBUG
  print_sem_vals(res->sem_id);
#endif
  if (perform_semop(res->sem_id, SI_SEM_TICKETS, -1, SEM_UNDO, &res->timeout) == -1) {
    res->error = errno;
  }
  return NULL;
}

static key_t
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


static void
initialize_new_semaphore_values(int sem_id, long permissions)
{
  unsigned short init_vals[SI_NUM_SEMAPHORES];

  init_vals[SI_SEM_TICKETS] = init_vals[SI_SEM_CONFIGURED_TICKETS] = 0;
  init_vals[SI_SEM_REGISTERED_WORKERS] = 0;
  init_vals[SI_SEM_LOCK] = 1;

  if (semctl(sem_id, 0, SETALL, init_vals) == -1) {
    raise_semian_syscall_error("semctl()", errno);
  }
#ifdef DEBUG
  print_sem_vals(sem_id);
#endif
}

static int
wait_for_new_semaphore_set(key_t key, long permissions)
{
  int i;
  int sem_id = -1;
  union semun sem_opts;
  struct semid_ds sem_ds;

  sem_opts.buf = &sem_ds;
  sem_id = semget(key, 1, permissions);

  if (sem_id == -1){
      raise_semian_syscall_error("semget()", errno);
  }

  for (i = 0; i < ((INTERNAL_TIMEOUT * MICROSECONDS_IN_SECOND) / INIT_WAIT); i++) {

    if (semctl(sem_id, 0, IPC_STAT, sem_opts) == -1) {
      raise_semian_syscall_error("semctl()", errno);
    }

    // If a semop has been performed by someone else, the values must be initialized
    if (sem_ds.sem_otime != 0) {
      break;
    }

#ifdef DEBUG
    printf("Waiting for another process to initialize semaphore values, checked: %d times\n", i);
#endif
    usleep(INIT_WAIT);
  }

  if (sem_ds.sem_otime == 0) {
    rb_raise(eTimeout, "error: timeout waiting for semaphore values to initialize after %d checks", INTERNAL_TIMEOUT);
  }

  return sem_id;
}
