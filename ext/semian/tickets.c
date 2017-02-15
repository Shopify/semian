#include <tickets.h>

VALUE
update_ticket_count(update_ticket_count_t *tc)
{
  short delta;
  struct timespec ts = { 0 };
  ts.tv_sec = INTERNAL_TIMEOUT;

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
        if ((cur_time.tv_sec - start_time.tv_sec) > INTERNAL_TIMEOUT) {
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
      sem_meta_lock(sem_id);

      tc.sem_id = sem_id;
      tc.tickets = tickets;
      rb_protect((VALUE (*)(VALUE)) update_ticket_count, (VALUE) &tc, &state);

      sem_meta_unlock(sem_id);

      if (state) {
        rb_jump_tag(state);
      }
    }
  }
}
