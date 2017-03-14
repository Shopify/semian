/*
For logic specific to manipulating semian ticket counts
*/
#ifndef SEMIAN_TICKETS_H
#define SEMIAN_TICKETS_H

#include "sysv_semaphores.h"

#ifndef max
// max is not defined in any standard, portable C header...
#define max(a,b) (((a)>(b))?(a):(b))
#endif

// Set initial ticket values upon resource creation
void
configure_tickets(int sem_id, int tickets, double quota, int min_tickets);

#endif // SEMIAN_TICKETS_H
