/*
For logic specific to manipulating semian ticket counts
*/
#ifndef SEMIAN_TICKETS_H
#define SEMIAN_TICKETS_H

#include <semian.h>

// Update the ticket count for static ticket tracking
VALUE
update_ticket_count(update_ticket_count_t *tc);

// Update ticket count based on quota
int
update_tickets_from_quota(int sem_id, double quota);

// Set initial ticket values upon resource creation
void
configure_tickets(int sem_id, int tickets, double quota, int should_initialize);

#endif // SEMIAN_TICKETS_H
