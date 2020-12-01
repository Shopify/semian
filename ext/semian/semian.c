#include "semian.h"

VALUE eSyscall, eTimeout, eInternal;

void Init_semian()
{
  VALUE cSemian, cResource;
  struct seminfo info_buf;

  cSemian = rb_const_get(rb_cObject, rb_intern("Semian"));

  /*
   * Document-class: Semian::Resource
   *
   *  Resource is the fundamental class of Semian. It is essentially a wrapper around a
   *  SystemV semaphore.
   *
   *  You should not create this class directly, it will be created indirectly via Semian.register.
   */
  cResource = rb_const_get(cSemian, rb_intern("Resource"));

  /* Document-class: Semian::SyscallError
   *
   * Represents a Semian error that was caused by an underlying syscall failure.
   */
  eSyscall = rb_const_get(cSemian, rb_intern("SyscallError"));
  rb_global_variable(&eSyscall);

  /* Document-class: Semian::TimeoutError
   *
   * Raised when a Semian operation timed out.
   */
  eTimeout = rb_const_get(cSemian, rb_intern("TimeoutError"));
  rb_global_variable(&eTimeout);

  /* Document-class: Semian::InternalError
   *
   * An internal Semian error. These errors should be typically never be raised. If
   * they do, there's a high likelyhood that the underlying SysV semaphore set
   * has been corrupted.
   *
   * If this happens, a strong course of action would be to delete the semaphores
   * using the <code>ipcrm</code> command line tool. Semian will re-initialize
   * the semaphore in this case.
   */
  eInternal = rb_const_get(cSemian, rb_intern("InternalError"));
  rb_global_variable(&eInternal);

  rb_define_alloc_func(cResource, semian_resource_alloc);
  rb_define_method(cResource, "initialize_semaphore", semian_resource_initialize, 6);
  rb_define_method(cResource, "acquire", semian_resource_acquire, -1);
  rb_define_method(cResource, "count", semian_resource_count, 0);
  rb_define_method(cResource, "semid", semian_resource_id, 0);
  rb_define_method(cResource, "key", semian_resource_key, 0);
  rb_define_method(cResource, "tickets", semian_resource_tickets, 0);
  rb_define_method(cResource, "registered_workers", semian_resource_workers, 0);
  rb_define_method(cResource, "destroy", semian_resource_destroy, 0);
  rb_define_method(cResource, "reset_registered_workers!", semian_resource_reset_workers, 0);
  rb_define_method(cResource, "unregister_worker", semian_resource_unregister_worker, 0);
  rb_define_method(cResource, "in_use?", semian_resource_in_use, 0);

  id_wait_time = rb_intern("wait_time");
  id_timeout = rb_intern("timeout");

  if (semctl(0, 0, SEM_INFO, &info_buf) == -1) {
    rb_raise(eInternal, "unable to determine maximum semaphore count - semctl() returned %d: %s ", errno, strerror(errno));
  }
  system_max_semaphore_count = info_buf.semvmx;

  /* Maximum number of tickets available on this system. */
  rb_define_const(cSemian, "MAX_TICKETS", INT2FIX(system_max_semaphore_count));
}
