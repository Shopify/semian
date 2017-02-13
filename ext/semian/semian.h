/*
System, 3rd party, and project includes

Implements Init_semian, which is used as C/Ruby entrypoint.
*/

#ifndef SEMIAN_H
#define SEMIAN_H

// System includes
#include <errno.h>
#include <string.h>
#include <stdio.h>

// 3rd party includes
#include <openssl/sha.h>
#include <ruby.h>
#include <ruby/util.h>
#include <ruby/io.h>

//semian includes
#include "types.h"
#include "resource.h"
#include "sysv_semaphores.h" // FIXME: TEMPORARY

void Init_semian();

// FIXME: These declarations will be modified in a subsequent PR
// temporarily placed here while refactoring
void
configure_tickets(int sem_id, int tickets, int should_initialize);

#endif //SEMIAN_H
