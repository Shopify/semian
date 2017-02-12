#ifndef SEMIAN_RESOURCE_H
#define SEMIAN_RESOURCE_H

#include <sys/types.h>
#include <ruby.h>

#include <semian_types.h>

void
semian_resource_mark(void *ptr);

void
semian_resource_free(void *ptr);

size_t
semian_resource_memsize(const void *ptr);

const rb_data_type_t
semian_resource_type;

VALUE
semian_resource_alloc(VALUE klass);

#endif //SEMIAN_RESOURCE_H
