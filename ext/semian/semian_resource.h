/*
For core semian resource functions exposed directly to ruby.

Functions here are associated with rubyland operations.
*/
#ifndef SEMIAN_RESOURCE_H
#define SEMIAN_RESOURCE_H

#include <semian.h>

/*
 * call-seq:
 *    Semian::Resource.new(id, tickets, permissions, default_timeout) -> resource
 *
 * Creates a new Resource. Do not create resources directly. Use Semian.register.
 */
VALUE
semian_resource_initialize(VALUE self, VALUE id, VALUE tickets, VALUE quota, VALUE permissions, VALUE default_timeout);

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
VALUE
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
VALUE
semian_resource_destroy(VALUE self);

/*
 * call-seq:
 *    resource.count -> count
 *
 * Returns the current ticket count for a resource.
 */
VALUE
semian_resource_count(VALUE self);

/*
 * call-seq:
 *    resource.semid -> id
 *
 * Returns the SysV semaphore id of a resource.
 */
VALUE
semian_resource_id(VALUE self);

// Private

VALUE
cleanup_semian_resource_acquire(VALUE self);

#endif //SEMIAN_RESOURCE_H
