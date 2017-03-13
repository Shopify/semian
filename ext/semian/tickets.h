/*
For logic specific to manipulating semian ticket counts
*/
#ifndef SEMIAN_TICKETS_H
#define SEMIAN_TICKETS_H

#include "sysv_semaphores.h"

// Set initial ticket values upon resource creation
void
configure_tickets(int sem_id, int tickets, double quota);

#endif // SEMIAN_TICKETS_H
