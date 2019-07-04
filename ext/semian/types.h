/*
For custom type definitions specific to semian
*/
#ifndef SEMIAN_TYPES_H
#define SEMIAN_TYPES_H

#include <stdint.h>
#include <sys/types.h>
#include <sys/ipc.h>
#include <sys/sem.h>
#include <sys/time.h>

#define SLIDING_WINDOW_MAX_SIZE 1000

// For sysV semop syscals
// see man semop
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
  double quota;
} configure_tickets_args_t;

// Internal semaphore structure
typedef struct {
  int sem_id;
  struct timespec timeout;
  double quota;
  int error;
  uint64_t key;
  char *strkey;
  char *name;
  long wait_time;
} semian_resource_t;

// Internal simple integer structure
typedef struct {
  uint64_t key;
  int sem_id;
} semian_simple_integer_t;

// Shared simple sliding window structure
typedef struct {
  int max_size;
  int length;
  int start;
  int data[SLIDING_WINDOW_MAX_SIZE];
} semian_simple_sliding_window_shared_t;

// Internal simple sliding window structure
typedef struct {
  uint64_t key;
  int sem_id;
  uint64_t parent_key;
  int error_threshold;
  float scale_factor;
  semian_simple_sliding_window_shared_t* shmem;
} semian_simple_sliding_window_t;

#endif // SEMIAN_TYPES_H
