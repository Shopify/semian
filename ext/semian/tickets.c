#include <tickets.h>

// "Private" function forward declarations
static void
initialize_tickets(int sem_id, int tickets);

static void
configure_static_tickets(int sem_id, int tickets);

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
void
configure_tickets(int sem_id, int tickets, int should_initialize)
{
  if (should_initialize) {
    initialize_tickets(sem_id, tickets);
  }

  if (tickets > 0) {
    configure_static_tickets(sem_id, tickets);
  }
}

/*
*********************************************************************************************************
"Private"

These functions are specific to semian ticket interals and may not be called by other files
*********************************************************************************************************
*/

static void
initialize_tickets(int sem_id, int tickets)
{
  unsigned short init_vals[SI_NUM_SEMAPHORES];

  if (tickets > 0) {
    init_vals[SI_SEM_TICKETS] = init_vals[SI_SEM_CONFIGURED_TICKETS] = tickets;
  }
  init_vals[SI_SEM_LOCK] = 1;
  if (semctl(sem_id, 0, SETALL, init_vals) == -1) {
    raise_semian_syscall_error("semctl()", errno);
  }
}

static void
configure_static_tickets(int sem_id, int tickets)
{
  int state;
  struct timeval start_time, cur_time;
  update_ticket_count_t tc;

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
