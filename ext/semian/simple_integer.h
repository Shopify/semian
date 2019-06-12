#ifndef EXT_SEMIAN_SIMPLE_INTEGER_H
#define EXT_SEMIAN_SIMPLE_INTEGER_H

#include <ruby.h>

void Init_SimpleInteger();

VALUE semian_simple_integer_alloc(VALUE klass);
VALUE semian_simple_integer_initialize(VALUE self, VALUE name);
VALUE semian_simple_integer_increment(int argc, VALUE *argv, VALUE self);
VALUE semian_simple_integer_reset(VALUE self);
VALUE semian_simple_integer_value_get(VALUE self);
VALUE semian_simple_integer_value_set(VALUE self, VALUE val);

#endif // EXT_SEMIAN_SIMPLE_INTEGER_H