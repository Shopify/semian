#ifndef SEMIAN_SEMSET_H
#define SEMIAN_SEMSET_H

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

static const char *SEMINDEX_STRING[] = {
    FOREACH_SEMINDEX(GENERATE_STRING)
};



#endif // SEMIAN_SEMSET_H
