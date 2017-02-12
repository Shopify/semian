#include <semian_tickets.h>

VALUE
update_ticket_count(update_ticket_count_t *tc)
{
  short delta;
  struct timespec ts = { 0 };
  ts.tv_sec = INTERNAL_TIMEOUT;

  if (get_sem_val(tc->sem_id, SI_SEM_CONFIGURED_TICKETS) != tc->tickets) {
    delta = tc->tickets - get_sem_val(tc->sem_id, SI_SEM_CONFIGURED_TICKETS);

    if (perform_semop(tc->sem_id, SI_SEM_TICKETS, delta, 0, &ts) == -1) {
      rb_raise(eInternal, "error setting ticket count, errno: %d (%s)", errno, strerror(errno));
    }

    if (semctl(tc->sem_id, SI_SEM_CONFIGURED_TICKETS, SETVAL, tc->tickets) == -1) {
      rb_raise(eInternal, "error updating configured ticket count, errno: %d (%s)", errno, strerror(errno));
    }
  }

  return Qnil;
}

int
update_tickets_from_quota(int sem_id, double quota)
{
  int delta = 0;
  int tickets = 0;
  int state;
  update_ticket_count_t tc;
  struct timespec ts = { 0 };

  ts.tv_sec = INTERNAL_TIMEOUT;

  //printf("Updating based on quota %f\n", quota);
  // If the configured worker count doesn't match the registered worker count, adjust it.
  // and adjust the underlying tickets available to match.
  delta = get_sem_val(sem_id, SI_SEM_REGISTERED_WORKERS) - get_sem_val(sem_id, SI_SEM_CONFIGURED_WORKERS);
  if (delta != 0) {
    if (perform_semop(sem_id, SI_SEM_CONFIGURED_WORKERS, delta, 0, &ts) == -1) {
      rb_raise(eInternal, "error setting configured workers, errno: %d (%s)", errno, strerror(errno));
    }

    // Compute the ticket count
    tickets = (int) ceil(get_sem_val(sem_id, SI_SEM_CONFIGURED_WORKERS) * quota);
    //printf("Configured ticket count %d with quota %f and workers %d\n", tickets, quota, get_sem_val(sem_id, SI_SEM_CONFIGURED_WORKERS));
    tc.sem_id = sem_id;
    tc.tickets = tickets;
    rb_protect((VALUE (*)(VALUE)) update_ticket_count, (VALUE) &tc, &state);
  }

  return state;
}

// Break this apart, handle quota case and static case separately
void
configure_tickets(int sem_id, int tickets, double quota, int should_initialize)
{
  struct timespec ts = { 0 };
  unsigned short init_vals[SI_NUM_SEMAPHORES];
  struct timeval start_time, cur_time;
  update_ticket_count_t tc;
  int state;

  if (should_initialize) {

    // desired tickets and configured tickets must be calculated based on quota if quota is provided
    // if a quoted is provided, should be initialzied to 0 instead of tickets

    // ticket was specified, not quota
    if (tickets > 0) {
      init_vals[SI_SEM_TICKETS] = init_vals[SI_SEM_CONFIGURED_TICKETS] = tickets;
      init_vals[SI_SEM_REGISTERED_WORKERS] = init_vals[SI_SEM_CONFIGURED_WORKERS] = 0;
    }
    // quota was specified, not tickets
    else if (quota > 0) {
      init_vals[SI_SEM_TICKETS] = init_vals[SI_SEM_CONFIGURED_TICKETS] = 0;
      init_vals[SI_SEM_REGISTERED_WORKERS] = init_vals[SI_SEM_CONFIGURED_WORKERS] = 0;
    }
    init_vals[SI_SEM_LOCK] = 1;
    if (semctl(sem_id, 0, SETALL, init_vals) == -1) {
      raise_semian_syscall_error("semctl()", errno);
    }
  } else if (tickets > 0) {
    /* it's possible that we haven't actually initialized the
       semaphore structure yet - wait a bit in that case */
    if (get_sem_val(sem_id, SI_SEM_CONFIGURED_TICKETS) == 0) {
      gettimeofday(&start_time, NULL);
      while (get_sem_val(sem_id, SI_SEM_CONFIGURED_TICKETS) == 0) {
        usleep(10000); /* 10ms */
        gettimeofday(&cur_time, NULL);
        if ((cur_time.tv_sec - start_time.tv_sec) > INTERNAL_TIMEOUT) {
          rb_raise(eInternal, "timeout waiting for semaphore initialization");
        }
      }
    }

    /*
       If the current configured ticket count is not the same as the requested ticket
       count, we need to resize the count. We do this by adding the delta of
       (tickets - current_configured_tickets) to the semaphore value.
    */
    if (get_sem_val(sem_id, SI_SEM_CONFIGURED_TICKETS) != tickets) {

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
  if (quota > 0) {
    // TO DO - is a spinwait needed here?
    sem_meta_lock(sem_id);

    // Ensure that a worker for this process is registered
    if (perform_semop(sem_id, SI_SEM_REGISTERED_WORKERS, 1, 0, &ts) == -1) {
      rb_raise(eInternal, "error incrementing registered workers, errno: %d (%s)", errno, strerror(errno));
    }

    // Ensure that our max tickets matches the quota
    state = update_tickets_from_quota(sem_id, quota);
    sem_meta_unlock(sem_id);

    if (state) {
      rb_jump_tag(state);
    }
  }
}


