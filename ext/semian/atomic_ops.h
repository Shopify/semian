/*
Lock-free atomic operations for shared memory using C11 stdatomic.h
*/
#ifndef SEMIAN_ATOMIC_OPS_H
#define SEMIAN_ATOMIC_OPS_H

#ifdef HAVE_STDATOMIC_H
#include <stdatomic.h>

static inline int
atomic_int_load(atomic_int *ptr)
{
  return atomic_load(ptr);
}

static inline void
atomic_int_store(atomic_int *ptr, int val)
{
  atomic_store(ptr, val);
}

static inline int
atomic_int_fetch_add(atomic_int *ptr, int val)
{
  return atomic_fetch_add(ptr, val);
}

static inline int
atomic_int_exchange(atomic_int *ptr, int val)
{
  return atomic_exchange(ptr, val);
}

static inline double
atomic_double_load(_Atomic double *ptr)
{
  return atomic_load(ptr);
}

static inline void
atomic_double_store(_Atomic double *ptr, double val)
{
  atomic_store(ptr, val);
}

static inline double
atomic_double_exchange(_Atomic double *ptr, double val)
{
  return atomic_exchange(ptr, val);
}

#else
#error "stdatomic.h not available - C11 compiler required"
#endif

#endif // SEMIAN_ATOMIC_OPS_H
