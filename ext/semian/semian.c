#include "semian.h"

// Time to wait for timed ops to complete
#define INTERNAL_TIMEOUT 5 // seconds

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
raise_semian_syscall_error(const char *syscall, int error_num)
{
  rb_raise(eSyscall, "%s failed, errno: %d (%s)", syscall, error_num, strerror(error_num));
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

static const int kInternalTimeout = 5; /* seconds */

static int
get_max_tickets(int sem_id)
{
  int ret = semctl(sem_id, SI_SEM_CONFIGURED_TICKETS, GETVAL);
  if (ret == -1) {
    rb_raise(eInternal, "error getting max ticket count, errno: %d (%s)", errno, strerror(errno));
  }
  return ret;
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

static VALUE
update_ticket_count(update_ticket_count_t *tc)
{
  short delta;
  struct timespec ts = { 0 };
  ts.tv_sec = kInternalTimeout;

  if (get_max_tickets(tc->sem_id) != tc->tickets) {
    delta = tc->tickets - get_max_tickets(tc->sem_id);

    if (perform_semop(tc->sem_id, SI_SEM_TICKETS, delta, 0, &ts) == -1) {
      rb_raise(eInternal, "error setting ticket count, errno: %d (%s)", errno, strerror(errno));
    }

    if (semctl(tc->sem_id, SI_SEM_CONFIGURED_TICKETS, SETVAL, tc->tickets) == -1) {
      rb_raise(eInternal, "error updating max ticket count, errno: %d (%s)", errno, strerror(errno));
    }
  }

  return Qnil;
}

void
configure_tickets(int sem_id, int tickets, int should_initialize)
{
  struct timespec ts = { 0 };
  unsigned short init_vals[SI_NUM_SEMAPHORES];
  struct timeval start_time, cur_time;
  update_ticket_count_t tc;
  int state;

  if (should_initialize) {
    init_vals[SI_SEM_TICKETS] = init_vals[SI_SEM_CONFIGURED_TICKETS] = tickets;
    init_vals[SI_SEM_LOCK] = 1;
    if (semctl(sem_id, 0, SETALL, init_vals) == -1) {
      raise_semian_syscall_error("semctl()", errno);
    }
  } else if (tickets > 0) {
    /* it's possible that we haven't actually initialized the
       semaphore structure yet - wait a bit in that case */
    if (get_max_tickets(sem_id) == 0) {
      gettimeofday(&start_time, NULL);
      while (get_max_tickets(sem_id) == 0) {
        usleep(10000); /* 10ms */
        gettimeofday(&cur_time, NULL);
        if ((cur_time.tv_sec - start_time.tv_sec) > kInternalTimeout) {
          rb_raise(eInternal, "timeout waiting for semaphore initialization");
        }
      }
    }

    /*
       If the current max ticket count is not the same as the requested ticket
       count, we need to resize the count. We do this by adding the delta of
       (tickets - current_max_tickets) to the semaphore value.
    */
    if (get_max_tickets(sem_id) != tickets) {
      ts.tv_sec = kInternalTimeout;

      if (perform_semop(sem_id, SI_SEM_LOCK, -1, SEM_UNDO, &ts) == -1) {
        raise_semian_syscall_error("error acquiring internal semaphore lock, semtimedop()", errno);
      }

      tc.sem_id = sem_id;
      tc.tickets = tickets;
      rb_protect((VALUE (*)(VALUE)) update_ticket_count, (VALUE) &tc, &state);

      if (perform_semop(sem_id, SI_SEM_LOCK, 1, SEM_UNDO, NULL) == -1) {
        raise_semian_syscall_error("error releasing internal semaphore lock, semop()", errno);
      }

      if (state) {
        rb_jump_tag(state);
      }
    }
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

void *
acquire_semaphore_without_gvl(void *p)
{
  semian_resource_t *res = (semian_resource_t *) p;
  res->error = 0;
  if (perform_semop(res->sem_id, SI_SEM_TICKETS, -1, SEM_UNDO, &res->timeout) == -1) {
    res->error = errno;
  }
  return NULL;
}

int
get_semaphore(int key)
{
  return semget(key, SI_NUM_SEMAPHORES, 0);
}

void Init_semian()
{
  VALUE cSemian, cResource;
  struct seminfo info_buf;

  cSemian = rb_const_get(rb_cObject, rb_intern("Semian"));

  /*
   * Document-class: Semian::Resource
   *
   *  Resource is the fundamental class of Semian. It is essentially a wrapper around a
   *  SystemV semaphore.
   *
   *  You should not create this class directly, it will be created indirectly via Semian.register.
   */
  cResource = rb_const_get(cSemian, rb_intern("Resource"));

  /* Document-class: Semian::SyscallError
   *
   * Represents a Semian error that was caused by an underlying syscall failure.
   */
  eSyscall = rb_const_get(cSemian, rb_intern("SyscallError"));

  /* Document-class: Semian::TimeoutError
   *
   * Raised when a Semian operation timed out.
   */
  eTimeout = rb_const_get(cSemian, rb_intern("TimeoutError"));

  /* Document-class: Semian::InternalError
   *
   * An internal Semian error. These errors should be typically never be raised. If
   * they do, there's a high likelyhood that the underlying SysV semaphore set
   * has been corrupted.
   *
   * If this happens, a strong course of action would be to delete the semaphores
   * using the <code>ipcrm</code> command line tool. Semian will re-initialize
   * the semaphore in this case.
   */
  eInternal = rb_const_get(cSemian, rb_intern("InternalError"));

  rb_define_alloc_func(cResource, semian_resource_alloc);
  rb_define_method(cResource, "initialize_semaphore", semian_resource_initialize, 4);
  rb_define_method(cResource, "acquire", semian_resource_acquire, -1);
  rb_define_method(cResource, "count", semian_resource_count, 0);
  rb_define_method(cResource, "semid", semian_resource_id, 0);
  rb_define_method(cResource, "destroy", semian_resource_destroy, 0);

  id_timeout = rb_intern("timeout");

  if (semctl(0, 0, SEM_INFO, &info_buf) == -1) {
    rb_raise(eInternal, "unable to determine maximum semaphore count - semctl() returned %d: %s ", errno, strerror(errno));
  }
  system_max_semaphore_count = info_buf.semvmx;

  /* Maximum number of tickets available on this system. */
  rb_define_const(cSemian, "MAX_TICKETS", INT2FIX(system_max_semaphore_count));
}
