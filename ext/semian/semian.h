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
#include "sysv_semaphores.h"

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

void Init_semian();

// FIXME: These are needed here temporarily while we move functions around
// Will be removed once there are new header files that the should belong to.
void
configure_tickets(int sem_id, int tickets, int should_initialize);

#endif //SEMIAN_H
