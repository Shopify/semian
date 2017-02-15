/*
System, 3rd party, and project includes

Implements Init_semian, which is used as C/Ruby entrypoint.
*/

#ifndef SEMIAN_H
#define SEMIAN_H

// semian includes
#include "types.h"
#include "resource.h"

void Init_semian();

// FIXME: These are needed here temporarily while we move functions around
// Will be removed once there are new header files that the should belong to.
void
configure_tickets(int sem_id, int tickets, int should_initialize);

#endif //SEMIAN_H
