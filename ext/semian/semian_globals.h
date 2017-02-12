/*
For global variables, declarations, or definitions.

Use of this file is discouraged, as it breaks encapsulation.

There are, however, some justified cases for appropriate globals.

*/
#ifndef SEMIAN_GLOBALS_H
#define SEMIAN_GLUBALS_H

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

#define INTERNAL_TIMEOUT 5 // seconds

// TODO: try and scope these to the correct files
ID id_timeout;
VALUE eSyscall, eTimeout, eInternal;
int system_max_semaphore_count;

#endif // SEMIAN_GLOBALS_H
