#ifndef SEMIAN_H
#define SEMIAN_H

// System includes
#include <sys/types.h>
#include <sys/ipc.h>
#include <sys/sem.h>
#include <sys/time.h>
#include <errno.h>
#include <string.h>
#include <stdio.h>

// 3rd party includes
#include <openssl/sha.h>
#include <ruby.h>
#include <ruby/util.h>
#include <ruby/io.h>

//semian includes
#include <semset.h>
#include <semian_types.h>
#include <semian_globals.h>
#include <semian_resource.h>
#include <semian_tickets.h>

void
ms_to_timespec(long ms, struct timespec *ts);

void Init_semian();

#endif //SEMIAN_H
