#ifndef EXT_SEMIAN_SLIDING_WINDOW_H
#define EXT_SEMIAN_SLIDING_WINDOW_H

#include <ruby.h>
#include "types.h"

void Init_SlidingWindow();

VALUE semian_simple_sliding_window_alloc(VALUE klass);
VALUE semian_simple_sliding_window_initialize(VALUE self, VALUE name, VALUE max_size, VALUE scale_factor);
VALUE semian_simple_sliding_window_size(VALUE self);
VALUE semian_simple_sliding_window_resize_to(VALUE self, VALUE new_size);
VALUE semian_simple_sliding_window_max_size_get(VALUE self);
VALUE semian_simple_sliding_window_max_size_set(VALUE self, VALUE new_size);
VALUE semian_simple_sliding_window_push(VALUE self, VALUE value);
VALUE semian_simple_sliding_window_values(VALUE self);
VALUE semian_simple_sliding_window_last(VALUE self);
VALUE semian_simple_sliding_window_clear(VALUE self);
VALUE semian_simple_sliding_window_reject(VALUE self);

#endif // EXT_SEMIAN_SLIDING_WINDOW_H
