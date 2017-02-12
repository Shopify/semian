/*
For memory management operations of semian resources.
*/
#ifndef SEMIAN_RESOURCE_ALLOC_H
#define SEMIAN_RESOURCE_ALLOC_H

#include <semian.h>

// Semian resource rep for GC purposes
const rb_data_type_t
semian_resource_type;

// Required, due to interface, but uneeded in implementation.
static inline void
semian_resource_mark(void *ptr)
{
  /* noop */
}

// Clean up a semian resource to prevent memory leakage
static inline void
semian_resource_free(void *ptr)
{
  semian_resource_t *res = (semian_resource_t *) ptr;
  if (res->name) {
    free(res->name);
    res->name = NULL;
  }
  xfree(res);
}

// Get memory size of the semian resource struct
static inline size_t
semian_resource_memsize(const void *ptr)
{
  return sizeof(semian_resource_t);
}

// Allocate heap space for semian resource struct
static inline VALUE
semian_resource_alloc(VALUE klass)
{
  semian_resource_t *res;
  VALUE obj = TypedData_Make_Struct(klass, semian_resource_t, &semian_resource_type, res);
  return obj;
}
#endif //SEMIAN_RESOURCE_ALLOC_H
