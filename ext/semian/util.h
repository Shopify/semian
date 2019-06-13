#ifndef EXT_SEMIAN_UTIL_H
#define EXT_SEMIAN_UTIL_H

#include <stdarg.h>
#include <stdio.h>

#include <openssl/sha.h>
#include <ruby.h>

#ifdef DEBUG
#  define DEBUG_TEST 1
#else
#  define DEBUG_TEST 0
#endif

#define dprintf(fmt, ...) \
  do { \
    if (DEBUG_TEST) { \
      printf("[DEBUG] %s:%d" fmt "\n", __FILE__, __LINE__, ##__VA_ARGS__); \
    } \
  } while (0)

const char* check_id_arg(VALUE id);

key_t generate_key(const char *name);

const char* to_s(VALUE obj);

#endif // EXT_SEMIAN_UTIL_H
