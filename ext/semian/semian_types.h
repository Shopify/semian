#ifndef SEMIAN_TYPES_H
#define SEMIAN_TYPES_H

#include <semian.h>

union semun {
  int              val;    /* Value for SETVAL */
  struct semid_ds *buf;    /* Buffer for IPC_STAT, IPC_SET */
  unsigned short  *array;  /* Array for GETALL, SETALL */
  struct seminfo  *__buf;  /* Buffer for IPC_INFO
                             (Linux-specific) */
};

typedef struct {
  int sem_id;
  int tickets;
} update_ticket_count_t;



typedef struct {
  int sem_id;
  struct timespec timeout;
  double quota;
  int error;
  char *name;
} semian_resource_t;

#endif // SEMIAN_TYPES_H
