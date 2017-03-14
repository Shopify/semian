/*
For custom type definitions specific to semian
*/
#ifndef SEMIAN_TYPES_H
#define SEMIAN_TYPES_H

#include <sys/types.h>
#include <sys/ipc.h>
#include <sys/sem.h>
#include <sys/time.h>

// For sysV semop syscals
// see man semop
union semun {
  int              val;    /* Value for SETVAL */
  struct semid_ds *buf;    /* Buffer for IPC_STAT, IPC_SET */
  unsigned short  *array;  /* Array for GETALL, SETALL */
  struct seminfo  *__buf;  /* Buffer for IPC_INFO
                             (Linux-specific) */
};

// To update the ticket count
typedef struct {
  int sem_id;
  int tickets;
} update_ticket_count_t;

// Internal semaphore structure
typedef struct {
  int sem_id;
  struct timespec timeout;
  double quota;
  int quota_grace_timeout;
  int error;
  char *name;
} semian_resource_t;

#endif // SEMIAN_TYPES_H
