/*
Lock-free atomic operations for shared memory.
*/
#ifndef SEMIAN_ATOMIC_OPS_H
#define SEMIAN_ATOMIC_OPS_H

#include <stdint.h>

#if defined(HAVE_GCC_ATOMIC) && (__SIZEOF_DOUBLE__ == 8)
  #define HAVE_ATOMIC_DOUBLE 1
#endif

static inline int
atomic_int_load(int *ptr)
{
#ifdef HAVE_GCC_ATOMIC
  return __atomic_load_n(ptr, __ATOMIC_SEQ_CST);
#else
  return *ptr;
#endif
}

static inline void
atomic_int_store(int *ptr, int val)
{
#ifdef HAVE_GCC_ATOMIC
  __atomic_store_n(ptr, val, __ATOMIC_SEQ_CST);
#else
  *ptr = val;
#endif
}

static inline int
atomic_int_fetch_add(int *ptr, int val)
{
#ifdef HAVE_GCC_ATOMIC
  return __atomic_fetch_add(ptr, val, __ATOMIC_SEQ_CST);
#else
  int old = *ptr;
  *ptr += val;
  return old;
#endif
}

static inline int
atomic_int_exchange(int *ptr, int val)
{
#ifdef HAVE_GCC_ATOMIC
  return __atomic_exchange_n(ptr, val, __ATOMIC_SEQ_CST);
#else
  int old = *ptr;
  *ptr = val;
  return old;
#endif
}

static inline double
atomic_double_load(double *ptr)
{
#ifdef HAVE_ATOMIC_DOUBLE
  union {
    uint64_t as_int;
    double as_double;
  } converter;
  converter.as_int = __atomic_load_n((uint64_t *)ptr, __ATOMIC_SEQ_CST);
  return converter.as_double;
#else
  return *ptr;
#endif
}

static inline void
atomic_double_store(double *ptr, double val)
{
#ifdef HAVE_ATOMIC_DOUBLE
  union {
    double as_double;
    uint64_t as_int;
  } converter;
  converter.as_double = val;
  __atomic_store_n((uint64_t *)ptr, converter.as_int, __ATOMIC_SEQ_CST);
#else
  *ptr = val;
#endif
}

static inline double
atomic_double_exchange(double *ptr, double val)
{
#ifdef HAVE_ATOMIC_DOUBLE
  union {
    double as_double;
    uint64_t as_int;
  } new_val, old_val;
  new_val.as_double = val;
  old_val.as_int = __atomic_exchange_n((uint64_t *)ptr, new_val.as_int, __ATOMIC_SEQ_CST);
  return old_val.as_double;
#else
  double old = *ptr;
  *ptr = val;
  return old;
#endif
}

#endif // SEMIAN_ATOMIC_OPS_H
