#ifndef SEMIAN_SEMSET_H
#define SEMIAN_SEMSET_H

#include <semian.h>

// Here we define an enum value and string representation of each semaphore
// This allows us to key the sem value and string rep in sync easily
// utilizing pre-processor macros.
//   SI_SEM_TICKETS             semaphore for the tickets currently issued
//   SI_SEM_CONFIGURED_TICKETS  semaphore to track the desired number of tickets available for issue
//   SI_SEM_LOCK                metadata lock to act as a mutex, ensuring thread-safety for updating other semaphores
//   SI_SEM_REGISTERED_WORKERS  semaphore for the number of workers currently registered
//   SI_SEM_CONFIGURED_WORKERS  semaphore for the number of workers that our quota is using for configured tickets
//   SI_NUM_SEMAPHORES          always leave this as last entry for count to be accurate
#define FOREACH_SEMINDEX(SEMINDEX) \
        SEMINDEX(SI_SEM_TICKETS)   \
        SEMINDEX(SI_SEM_CONFIGURED_TICKETS)  \
        SEMINDEX(SI_SEM_LOCK)   \
        SEMINDEX(SI_SEM_REGISTERED_WORKERS)  \
        SEMINDEX(SI_SEM_CONFIGURED_WORKERS)  \
        SEMINDEX(SI_NUM_SEMAPHORES)  \

#define GENERATE_ENUM(ENUM) ENUM,
#define GENERATE_STRING(STRING) #STRING,

enum SEMINDEX_ENUM {
    FOREACH_SEMINDEX(GENERATE_ENUM)
};

extern const char *SEMINDEX_STRING[];

void
raise_semian_syscall_error(const char *syscall, int error_num);

key_t
generate_sem_set_key(const char *name);


void
set_semaphore_permissions(int sem_id, int permissions);

int
get_sem_val(int sem_id, int sem_index);

int
perform_semop(int sem_id, short index, short op, short flags, struct timespec *ts);

void
sem_meta_lock(int sem_id);

void
sem_meta_unlock(int sem_id);

int
create_semaphore(int key, int permissions, int *created);

int
get_semaphore(int key);

void *
acquire_semaphore_without_gvl(void *p);


#endif // SEMIAN_SEMSET_H
