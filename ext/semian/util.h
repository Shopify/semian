#ifndef EXT_SEMIAN_UTIL_H
#define EXT_SEMIAN_UTIL_H

#include <stdarg.h>
#include <stdio.h>
#include <time.h>

#include <openssl/sha.h>
#include <ruby.h>

#if defined(DEBUG) || defined(SEMIAN_DEBUG)
#  define DEBUG_TEST 1
#else
#  define DEBUG_TEST 0
#endif

#define dprintf(fmt, ...) \
  do { \
    if (DEBUG_TEST) { \
      const pid_t pid = getpid(); \
      struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts); \
      struct tm t; localtime_r(&(ts.tv_sec), &t); \
      char buf[128]; strftime(buf, sizeof(buf), "%H:%M:%S", &t); \
      printf("%s.%ld [DEBUG] (%d): %s:%d - " fmt "\n", buf, ts.tv_nsec, pid, __FILE__, __LINE__, ##__VA_ARGS__); \
    } \
  } while (0)

const char* check_id_arg(VALUE id);

key_t generate_key(const char *name);

const char* to_s(VALUE obj);

#endif // EXT_SEMIAN_UTIL_H
