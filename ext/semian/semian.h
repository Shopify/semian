#ifndef SEMIAN_H
#define SEMIAN_H

// System includes
#include <sys/types.h>
#include <sys/ipc.h>
#include <sys/sem.h>
#include <errno.h>
#include <string.h>
#include <stdio.h>

// 3rd party includes
#include <openssl/sha.h>
#include <ruby.h>
#include <ruby/util.h>
#include <ruby/io.h>

//semian includes
#include <semset.h>
#include <semian_types.h>
#include <semian_globals.h>
#include <semian_resource.h>

static void
ms_to_timespec(long ms, struct timespec *ts);

static void
raise_semian_syscall_error(const char *syscall, int error_num);

static key_t
generate_key(const char *name);


static void
set_semaphore_permissions(int sem_id, int permissions);

static int
get_sem_val(int sem_id, int sem_index);

static int
perform_semop(int sem_id, short index, short op, short flags, struct timespec *ts);

static VALUE
update_ticket_count(update_ticket_count_t *tc);

static void
sem_meta_lock(int sem_id);

static void
sem_meta_unlock(int sem_id);

static int
update_tickets_from_quota(int sem_id, double quota);

static void
configure_tickets(int sem_id, int tickets, double quota, int should_initialize);

static int
create_semaphore(int key, int permissions, int *created);

static int
get_semaphore(int key);


/*
 * call-seq:
 *    Semian::Resource.new(id, tickets, permissions, default_timeout) -> resource
 *
 * Creates a new Resource. Do not create resources directly. Use Semian.register.
 */

static VALUE
semian_resource_initialize(VALUE self, VALUE id, VALUE tickets, VALUE quota, VALUE permissions, VALUE default_timeout);

static VALUE
cleanup_semian_resource_acquire(VALUE self);

static void *
acquire_semaphore_without_gvl(void *p);

/*
 * call-seq:
 *    resource.acquire(timeout: default_timeout) { ... }  -> result of the block
 *
 * Acquires a resource. The call will block for <code>timeout</code> seconds if a ticket
 * is not available. If no ticket is available within the timeout period, Semian::TimeoutError
 * will be raised.
 *
 * If no timeout argument is provided, the default timeout passed to Semian.register will be used.
 *
 */
static VALUE
semian_resource_acquire(int argc, VALUE *argv, VALUE self);

/*
 * call-seq:
 *   resource.destroy() -> true
 *
 * Destroys a resource. This method will destroy the underlying SysV semaphore.
 * If there is any code in other threads or processes blocking or using the resource
 * they will likely raise.
 *
 * Use this method very carefully.
 */
static VALUE
semian_resource_destroy(VALUE self);

/*
 * call-seq:
 *    resource.count -> count
 *
 * Returns the current ticket count for a resource.
 */
static VALUE
semian_resource_count(VALUE self);

/*
 * call-seq:
 *    resource.semid -> id
 *
 * Returns the SysV semaphore id of a resource.
 */
static VALUE
semian_resource_id(VALUE self);

void Init_semian();

#endif //SEMIAN_H
