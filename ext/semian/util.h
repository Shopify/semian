#ifndef EXT_SEMIAN_UTIL_H
#define EXT_SEMIAN_UTIL_H

#include <stdarg.h>
#include <stdio.h>
#include <time.h>

#ifdef DEBUG
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

#endif // EXT_SEMIAN_UTIL_H
