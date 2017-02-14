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

VALUE eSyscall, eTimeout, eInternal;

void Init_semian();

// FIXME: These are needed here temporarily while we move functions around
// Will be removed once there are new header files that the should belong to.
void
configure_tickets(int sem_id, int tickets, int should_initialize);

key_t
generate_sem_set_key(const char *name);

void
set_semaphore_permissions(int sem_id, long permissions);

int
create_semaphore(int key, long permissions, int *created);

int
get_semaphore(int key);

void
raise_semian_syscall_error(const char *syscall, int error_num);

int
perform_semop(int sem_id, short index, short op, short flags, struct timespec *ts);

void *
acquire_semaphore_without_gvl(void *p);

#endif //SEMIAN_H
