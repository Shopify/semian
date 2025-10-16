/*
 * Shared Memory PID Controller Implementation
 */
#include "pid_controller_shared.h"
#include "sysv_semaphores.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <math.h>
#include <sys/time.h>
#include <openssl/sha.h>
#include <ruby.h>

// External error class from semian
extern VALUE eSyscall, eInternal;

/*
 * Generate IPC key from resource name
 *
 * Uses SHA1 hash with "_pid" suffix to avoid collisions with bulkhead keys.
 * This follows the same pattern as generate_key() in sysv_semaphores.c
 */
static key_t
generate_pid_key(const char *name)
{
    // Append "_pid" suffix to resource name
    size_t name_len = strlen(name);
    size_t pid_name_len = name_len + 5; // "_pid" + null terminator
    char *pid_name = malloc(pid_name_len);
    if (pid_name == NULL) {
        rb_raise(eInternal, "malloc failed for pid_name");
    }
    
    snprintf(pid_name, pid_name_len, "%s_pid", name);
    
    // SHA1 hash
    unsigned char hash[SHA_DIGEST_LENGTH];
    SHA1((unsigned char*)pid_name, strlen(pid_name), hash);
    
    // Convert first sizeof(key_t) bytes to key
    key_t key;
    memcpy(&key, hash, sizeof(key_t));
    
    free(pid_name);
    return key;
}

/*
 * Initialize a process-shared, robust mutex
 *
 * PTHREAD_PROCESS_SHARED: Allows mutex to work across processes
 * PTHREAD_MUTEX_ROBUST: If a process dies while holding the mutex,
 *                       the next lock attempt returns EOWNERDEAD
 */
static void
initialize_process_shared_mutex(pthread_mutex_t *mutex)
{
    pthread_mutexattr_t attr;
    int rc;
    
    rc = pthread_mutexattr_init(&attr);
    if (rc != 0) {
        rb_raise(eInternal, "pthread_mutexattr_init failed: %d (%s)", rc, strerror(rc));
    }
    
    // Make mutex shared across processes
    rc = pthread_mutexattr_setpshared(&attr, PTHREAD_PROCESS_SHARED);
    if (rc != 0) {
        pthread_mutexattr_destroy(&attr);
        rb_raise(eInternal, "pthread_mutexattr_setpshared failed: %d (%s)", rc, strerror(rc));
    }
    
    // Make mutex robust (survives process crashes)
    rc = pthread_mutexattr_setrobust(&attr, PTHREAD_MUTEX_ROBUST);
    if (rc != 0) {
        pthread_mutexattr_destroy(&attr);
        rb_raise(eInternal, "pthread_mutexattr_setrobust failed: %d (%s)", rc, strerror(rc));
    }
    
    rc = pthread_mutex_init(mutex, &attr);
    if (rc != 0) {
        pthread_mutexattr_destroy(&attr);
        rb_raise(eInternal, "pthread_mutex_init failed: %d (%s)", rc, strerror(rc));
    }
    
    pthread_mutexattr_destroy(&attr);
}

/*
 * Get current monotonic time in seconds (as double for precision)
 */
static double
get_monotonic_time(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1000000000.0;
}

/*
 * Initialize or attach to shared PID controller
 *
 * This implements the same pattern as initialize_semaphore_set in sysv_semaphores.c:
 * - First process creates and initializes
 * - Subsequent processes attach and wait for initialization
 * - Race conditions are handled via the initialized flag
 */
void
initialize_pid_controller(
    semian_pid_controller_t *pid,
    const char *name,
    long permissions,
    double kp,
    double ki,
    double kd,
    double window_size,
    double target_error_rate)
{
    int is_creator = 0;
    
    pid->key = generate_pid_key(name);
    pid->name = strdup(name);
    if (pid->name == NULL) {
        rb_raise(eInternal, "strdup failed for name");
    }
    
    // Try to create new shared memory segment
    pid->shm_id = shmget(pid->key, sizeof(pid_controller_state_t),
                         IPC_CREAT | IPC_EXCL | permissions);
    
    if (pid->shm_id == -1) {
        if (errno == EEXIST) {
            // Segment already exists, attach to it
            pid->shm_id = shmget(pid->key, sizeof(pid_controller_state_t), permissions);
            if (pid->shm_id == -1) {
                if (errno == EACCES) {
                    rb_raise(eInternal, "Permission denied accessing shared memory for '%s'. "
                            "Check that all processes use the same permissions (0%o)", name, (int)permissions);
                }
                raise_semian_syscall_error("shmget() attach failed", errno);
            }
        } else if (errno == EACCES) {
            rb_raise(eInternal, "Permission denied creating shared memory for '%s'. "
                    "Check system IPC permissions", name);
        } else if (errno == ENOMEM || errno == ENOSPC) {
            rb_raise(eInternal, "Insufficient system resources for shared memory. "
                    "Try increasing system limits (kern.sysv.shmmni, kern.sysv.shmmax)");
        } else {
            raise_semian_syscall_error("shmget() create failed", errno);
        }
    } else {
        is_creator = 1;
    }
    
    // Attach shared memory to our address space
    pid->state = (pid_controller_state_t *)shmat(pid->shm_id, NULL, 0);
    if (pid->state == (void *)-1) {
        raise_semian_syscall_error("shmat() failed", errno);
    }
    
    if (is_creator) {
        // We created the segment, initialize it
        memset(pid->state, 0, sizeof(pid_controller_state_t));
        
        // Initialize mutex FIRST (before any other field)
        initialize_process_shared_mutex(&pid->state->lock);
        
        // Set configuration (immutable)
        pid->state->kp = kp;
        pid->state->ki = ki;
        pid->state->kd = kd;
        pid->state->window_size = window_size;
        pid->state->target_error_rate = target_error_rate;
        
        // Initialize state
        pid->state->rejection_rate = 0.0;
        pid->state->integral = 0.0;
        pid->state->previous_error = 0.0;
        
        double now = get_monotonic_time();
        pid->state->last_update_time = now;
        pid->state->window_start_time = (uint64_t)now;
        
        // Counters are already zeroed by memset
        
        pid->state->last_error_rate = 0.0;
        pid->state->last_ping_failure_rate = 0.0;
        
        // History
        pid->state->history_index = 0;
        pid->state->history_count = 0;
        
        // Metadata
        pid->state->creator_pid = getpid();
        
        // Mark as initialized (LAST - this is the signal to other processes)
        __sync_synchronize(); // Memory barrier
        pid->state->initialized = 1;
    } else {
        // Wait for creator to finish initialization
        // Poll with exponential backoff, timeout after PID_INIT_TIMEOUT seconds
        struct timeval start_time, current_time;
        gettimeofday(&start_time, NULL);
        
        int wait_time = PID_INIT_POLL_INTERVAL; // Start with 1ms
        while (!pid->state->initialized) {
            usleep(wait_time);
            
            // Exponential backoff, max 100ms
            wait_time = wait_time * 2;
            if (wait_time > 100000) {
                wait_time = 100000;
            }
            
            // Check timeout
            gettimeofday(&current_time, NULL);
            double elapsed = (current_time.tv_sec - start_time.tv_sec) + 
                           (current_time.tv_usec - start_time.tv_usec) / 1000000.0;
            if (elapsed > PID_INIT_TIMEOUT) {
                rb_raise(eInternal, "timeout waiting for PID controller initialization");
            }
        }
    }
}

/*
 * Acquire mutex with EOWNERDEAD handling
 *
 * If the previous owner died while holding the mutex, we get EOWNERDEAD.
 * In this case, we mark the mutex as consistent and continue.
 */
static void
lock_pid_mutex(pthread_mutex_t *mutex)
{
    int rc = pthread_mutex_lock(mutex);
    
    if (rc == EOWNERDEAD) {
        // Previous owner died, make mutex consistent
        pthread_mutex_consistent(mutex);
    } else if (rc != 0) {
        rb_raise(eInternal, "pthread_mutex_lock failed: %d (%s)", rc, strerror(rc));
    }
}

/*
 * Release mutex
 */
static void
unlock_pid_mutex(pthread_mutex_t *mutex)
{
    int rc = pthread_mutex_unlock(mutex);
    if (rc != 0) {
        rb_raise(eInternal, "pthread_mutex_unlock failed: %d (%s)", rc, strerror(rc));
    }
}

/*
 * Record a request outcome
 */
void
record_request_shared(semian_pid_controller_t *pid, const char *outcome)
{
    lock_pid_mutex(&pid->state->lock);
    
    if (strcmp(outcome, "success") == 0) {
        pid->state->window_success++;
    } else if (strcmp(outcome, "error") == 0) {
        pid->state->window_error++;
    } else if (strcmp(outcome, "rejected") == 0) {
        pid->state->window_rejected++;
    }
    
    unlock_pid_mutex(&pid->state->lock);
}

/*
 * Record a ping outcome
 */
void
record_ping_shared(semian_pid_controller_t *pid, const char *outcome)
{
    lock_pid_mutex(&pid->state->lock);
    
    if (strcmp(outcome, "success") == 0) {
        pid->state->window_ping_success++;
    } else {
        pid->state->window_ping_failure++;
    }
    
    unlock_pid_mutex(&pid->state->lock);
}

/*
 * Calculate p90 from error rate history
 */
static double
calculate_p90_error_rate(pid_controller_state_t *state)
{
    if (state->history_count == 0) {
        return 0.01; // Default 1%
    }
    
    // Copy history for sorting (don't modify original)
    double sorted[PID_HISTORY_SIZE];
    int count = state->history_count;
    memcpy(sorted, state->error_rate_history, count * sizeof(double));
    
    // Simple bubble sort (sufficient for small arrays)
    for (int i = 0; i < count - 1; i++) {
        for (int j = 0; j < count - i - 1; j++) {
            if (sorted[j] > sorted[j + 1]) {
                double temp = sorted[j];
                sorted[j] = sorted[j + 1];
                sorted[j + 1] = temp;
            }
        }
    }
    
    // Get p90
    int index = (int)(count * 0.9) - 1;
    if (index < 0) index = 0;
    double p90 = sorted[index];
    
    // Cap at 10%
    return (p90 < 0.1) ? p90 : 0.1;
}

/*
 * Clamp value between min and max
 */
static double
clamp(double value, double min, double max)
{
    if (value < min) return min;
    if (value > max) return max;
    return value;
}

/*
 * Update PID controller at end of time window
 *
 * This implements the PID control algorithm:
 * 1. Calculate current error rate and ping failure rate
 * 2. Store error rate in history
 * 3. Calculate ideal error rate (target or p90)
 * 4. Calculate health metric P
 * 5. Compute PID terms (proportional, integral, derivative)
 * 6. Update rejection rate
 * 7. Reset window counters
 */
double
update_pid_controller_shared(semian_pid_controller_t *pid)
{
    lock_pid_mutex(&pid->state->lock);
    
    pid_controller_state_t *s = pid->state;
    
    // Calculate current window rates
    uint64_t total_requests = s->window_success + s->window_error;
    double current_error_rate = 0.0;
    if (total_requests > 0) {
        current_error_rate = (double)s->window_error / (double)total_requests;
    }
    s->last_error_rate = current_error_rate;
    
    uint64_t total_pings = s->window_ping_success + s->window_ping_failure;
    double ping_failure_rate = 0.0;
    if (total_pings > 0) {
        ping_failure_rate = (double)s->window_ping_failure / (double)total_pings;
    }
    s->last_ping_failure_rate = ping_failure_rate;
    
    // Store error rate in history (circular buffer)
    s->error_rate_history[s->history_index] = current_error_rate;
    s->history_index = (s->history_index + 1) % PID_HISTORY_SIZE;
    if (s->history_count < PID_HISTORY_SIZE) {
        s->history_count++;
    }
    
    // Reset window counters for next window
    s->window_success = 0;
    s->window_error = 0;
    s->window_rejected = 0;
    s->window_ping_success = 0;
    s->window_ping_failure = 0;
    
    double now = get_monotonic_time();
    s->window_start_time = (uint64_t)now;
    
    // Calculate ideal error rate (target or p90)
    double ideal_error_rate;
    if (s->target_error_rate > 0) {
        ideal_error_rate = s->target_error_rate;
    } else {
        ideal_error_rate = calculate_p90_error_rate(s);
    }
    
    // Calculate health metric P
    // P = (error_rate - ideal_error_rate) - (rejection_rate - ping_failure_rate)
    double health_metric = (current_error_rate - ideal_error_rate) - 
                          (s->rejection_rate - ping_failure_rate);
    
    // PID calculations
    double dt = s->window_size;
    
    double proportional = s->kp * health_metric;
    s->integral += health_metric * dt;
    double integral_term = s->ki * s->integral;
    double derivative = s->kd * (health_metric - s->previous_error) / dt;
    
    // Control signal
    double control_signal = proportional + integral_term + derivative;
    
    // Update rejection rate (clamped 0-1)
    s->rejection_rate = clamp(s->rejection_rate + control_signal, 0.0, 1.0);
    
    // Update state for next iteration
    s->previous_error = health_metric;
    s->last_update_time = now;
    
    double result = s->rejection_rate;
    
    unlock_pid_mutex(&pid->state->lock);
    
    return result;
}

/*
 * Check if request should be rejected
 *
 * Generates a random number and compares against rejection_rate.
 * Thread and process safe.
 */
int
should_reject_shared(semian_pid_controller_t *pid)
{
    lock_pid_mutex(&pid->state->lock);
    double rejection_rate = pid->state->rejection_rate;
    unlock_pid_mutex(&pid->state->lock);
    
    // Generate random number [0.0, 1.0)
    double random = (double)rand() / (double)RAND_MAX;
    
    return random < rejection_rate;
}

/*
 * Get current rejection rate
 */
double
get_rejection_rate_shared(semian_pid_controller_t *pid)
{
    lock_pid_mutex(&pid->state->lock);
    double rate = pid->state->rejection_rate;
    unlock_pid_mutex(&pid->state->lock);
    
    return rate;
}

/*
 * Detach from shared memory
 *
 * This does NOT remove the shared memory segment - other processes
 * may still be using it.
 */
void
destroy_pid_controller_shared(semian_pid_controller_t *pid)
{
    if (pid->state != NULL) {
        shmdt(pid->state);
        pid->state = NULL;
    }
    
    if (pid->name != NULL) {
        free(pid->name);
        pid->name = NULL;
    }
}

/*
 * Remove shared memory segment
 *
 * Marks the segment for deletion. It will be removed when the last
 * process detaches. Should only be called by Semian.destroy.
 */
void
remove_pid_controller_shm(semian_pid_controller_t *pid)
{
    if (pid->shm_id != -1) {
        shmctl(pid->shm_id, IPC_RMID, NULL);
    }
}

