/*
For logic specific to manipulating semian ticket counts
*/
#ifndef SEMIAN_TICKETS_H
#define SEMIAN_TICKETS_H

#include <semian.h>

// Update the ticket count for static ticket tracking
VALUE
update_ticket_count(update_ticket_count_t *tc);

// Set initial ticket values upon resource creation
void
configure_tickets(int sem_id, int tickets, int should_initialize);

#endif // SEMIAN_TICKETS_H
