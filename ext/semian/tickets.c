#include "tickets.h"

// Update the ticket count for static ticket tracking
static VALUE
update_ticket_count(update_ticket_count_t *tc);

static int
calculate_quota_tickets(int sem_id, double quota);

// Must be called with the semaphore meta lock already acquired
void
configure_tickets(int sem_id, int tickets, double quota)
{
  int state = 0;
  update_ticket_count_t tc;

  if (quota > 0) {
    tickets = calculate_quota_tickets(sem_id, quota);
  }

  /*
    A manually specified ticket count of 0 is special, meaning "don't set"
    We need to throw an error if we set it to 0 during initialization.
    Otherwise, we back out of here completely.
  */
  if (get_sem_val(sem_id, SI_SEM_CONFIGURED_TICKETS) == 0 && tickets == 0) {
    rb_raise(eSyscall, "More than 0 tickets must be specified when initializing semaphore");
  } else if (tickets == 0) {
    return;
  }

  /*
     If the current configured ticket count is not the same as the requested ticket
     count, we need to resize the count. We do this by adding the delta of
     (tickets - current_configured_tickets) to the semaphore value.
  */
  if (get_sem_val(sem_id, SI_SEM_CONFIGURED_TICKETS) != tickets) {

    tc.sem_id = sem_id;
    tc.tickets = tickets;
    rb_protect((VALUE (*)(VALUE)) update_ticket_count, (VALUE) &tc, &state);

    if (state) {
      rb_jump_tag(state);
    }
  }
}

static VALUE
update_ticket_count(update_ticket_count_t *tc)
{
  short delta;
  struct timespec ts = { 0 };
  ts.tv_sec = INTERNAL_TIMEOUT;

  delta = tc->tickets - get_sem_val(tc->sem_id, SI_SEM_CONFIGURED_TICKETS);

#ifdef DEBUG
  print_sem_vals(tc->sem_id);
#endif
  if (perform_semop(tc->sem_id, SI_SEM_TICKETS, delta, 0, &ts) == -1) {
    if (delta < 0 && errno == EAGAIN) {
      rb_raise(eTimeout, "timeout while trying to update ticket count");
    } else {
      rb_raise(eInternal, "error setting ticket count, errno: %d (%s)", errno, strerror(errno));
    }
  }

  if (semctl(tc->sem_id, SI_SEM_CONFIGURED_TICKETS, SETVAL, tc->tickets) == -1) {
    rb_raise(eInternal, "error configuring ticket count, errno: %d (%s)", errno, strerror(errno));
  }

  return Qnil;
}

static int
calculate_quota_tickets (int sem_id, double quota)
{
  int tickets = 0;
  tickets = (int) ceil(get_sem_val(sem_id, SI_SEM_REGISTERED_WORKERS) * quota);
  return tickets;
}
