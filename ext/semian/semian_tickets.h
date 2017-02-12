/*
For logic specific to manipulating semian ticket counts
*/
#ifndef SEMIAN_TICKETS_H
#define SEMIAN_TICKETS_H

#include <semian.h>

VALUE
update_ticket_count(update_ticket_count_t *tc);

int
update_tickets_from_quota(int sem_id, double quota);

void
configure_tickets(int sem_id, int tickets, double quota, int should_initialize);

#endif // SEMIAN_TICKETS_H
