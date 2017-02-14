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
  int error;
  char *name;
} semian_resource_t;

// FIXME: move this to more appropriate location once the file exists
typedef enum
{
  SI_SEM_TICKETS,            // semaphore for the tickets currently issued
  SI_SEM_CONFIGURED_TICKETS, // semaphore to track the desired number of tickets available for issue
  SI_SEM_LOCK,               // metadata lock to act as a mutex, ensuring thread-safety for updating other semaphores
  SI_NUM_SEMAPHORES          // always leave this as last entry for count to be accurate
} semaphore_indices;

#endif // SEMIAN_TYPES_H
