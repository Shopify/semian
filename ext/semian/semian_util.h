/*
Strictly for utility / convenience functions
*/
#ifndef SEMIAN_UTIL_H
#define SEMIAN_UTIL_H

#include <semian.h>

static inline void
ms_to_timespec(long ms, struct timespec *ts)
{
  ts->tv_sec = ms / 1000;
  ts->tv_nsec = (ms % 1000) * 1000000;
}
#endif //SEMIAN_UTIL_H
