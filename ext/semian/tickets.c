#include "tickets.h"

// Update the ticket count for static ticket tracking
static VALUE
update_ticket_count(int sem_id, int count);

static int
calculate_quota_tickets(int sem_id, double quota);

// Must be called with the semaphore meta lock already acquired
VALUE
configure_tickets(VALUE value)
{
  configure_tickets_args_t *args = (configure_tickets_args_t *)value;

  if (args->quota > 0) {
    args->tickets = calculate_quota_tickets(args->sem_id, args->quota);
  }

  /*
    A manually specified ticket count of 0 is special, meaning "don't set"
    We need to throw an error if we set it to 0 during initialization.
    Otherwise, we back out of here completely.
  */
  if (get_sem_val(args->sem_id, SI_SEM_CONFIGURED_TICKETS) == 0 && args->tickets == 0) {
    rb_raise(eSyscall, "More than 0 tickets must be specified when initializing semaphore");
  } else if (args->tickets == 0) {
    return Qnil;
  }

  /*
     If the current configured ticket count is not the same as the requested ticket
     count, we need to resize the count. We do this by adding the delta of
     (tickets - current_configured_tickets) to the semaphore value.
  */
  if (get_sem_val(args->sem_id, SI_SEM_CONFIGURED_TICKETS) != args->tickets) {
    update_ticket_count(args->sem_id, args->tickets);
  }

  return Qnil;
}

static VALUE
update_ticket_count(int sem_id, int tickets)
{
  short delta;
  struct timespec ts = { 0 };
  ts.tv_sec = INTERNAL_TIMEOUT;

  delta = tickets - get_sem_val(sem_id, SI_SEM_CONFIGURED_TICKETS);

#ifdef DEBUG
  print_sem_vals(sem_id);
#endif
  if (perform_semop(sem_id, SI_SEM_TICKETS, delta, 0, &ts) == -1) {
    if (delta < 0 && errno == EAGAIN) {
      rb_raise(eTimeout, "timeout while trying to update ticket count");
    } else {
      rb_raise(eInternal, "error setting ticket count, errno: %d (%s)", errno, strerror(errno));
    }
  }

  if (semctl(sem_id, SI_SEM_CONFIGURED_TICKETS, SETVAL, tickets) == -1) {
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
