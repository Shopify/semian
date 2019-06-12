#ifndef EXT_SEMIAN_UTIL_H
#define EXT_SEMIAN_UTIL_H

#include <openssl/sha.h>
#include <ruby.h>

const char* check_id_arg(VALUE id);

key_t generate_key(const char *name);

const char* to_s(VALUE obj);

#endif // EXT_SEMIAN_UTIL_H
