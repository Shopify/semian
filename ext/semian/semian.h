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

// FIXME: This is needed here temporarily
// Defines for ruby threading primitives
#if defined(HAVE_RB_THREAD_CALL_WITHOUT_GVL) && defined(HAVE_RUBY_THREAD_H)
// 2.0
#include <ruby/thread.h>
#define WITHOUT_GVL(fn,a,ubf,b) rb_thread_call_without_gvl((fn),(a),(ubf),(b))
#elif defined(HAVE_RB_THREAD_BLOCKING_REGION)
 // 1.9
typedef VALUE (*my_blocking_fn_t)(void*);
#define WITHOUT_GVL(fn,a,ubf,b) rb_thread_blocking_region((my_blocking_fn_t)(fn),(a),(ubf),(b))
#endif

VALUE eSyscall, eTimeout, eInternal;

void Init_semian();

// FIXME: These are needed here temporarily while we move functions around
// Will be removed once there are new header files that the should belong to.
void
configure_tickets(int sem_id, int tickets, int should_initialize);

key_t
generate_key(const char *name);

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
