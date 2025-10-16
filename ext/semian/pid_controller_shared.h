/*
 * Shared Memory PID Controller for Host-Wide Coordination
 *
 * This implements a PID controller that uses SysV shared memory for
 * inter-process communication, allowing all worker processes within
 * a pod to share the same circuit breaker state.
 */
#ifndef SEMIAN_PID_CONTROLLER_SHARED_H
#define SEMIAN_PID_CONTROLLER_SHARED_H

#include <stdint.h>
#include <sys/types.h>
#include <sys/ipc.h>
#include <sys/shm.h>
#include <pthread.h>
#include <time.h>

// History size: 1 hour of 10-second windows = 360 entries
#define PID_HISTORY_SIZE 360

// Timeout for waiting on initialization (seconds)
#define PID_INIT_TIMEOUT 5

// Initialization polling interval (microseconds)
#define PID_INIT_POLL_INTERVAL 1000

/*
 * Shared state structure - lives in shared memory
 *
 * This structure is mapped into the address space of all processes
 * that access the same PID controller resource. All fields are
 * protected by the mutex for thread and process safety.
 *
 * Memory layout is optimized to minimize false sharing:
 * - Mutex is cache-line aligned (64 bytes)
 * - Hot data (rejection_rate, counters) grouped together
 * - History data placed at end
 */
typedef struct {
    // Synchronization (cache-line aligned to avoid false sharing)
    pthread_mutex_t lock __attribute__((aligned(64)));
    
    // PID controller state (hot data - frequently accessed)
    double rejection_rate;          // Current rejection rate [0.0, 1.0]
    double integral;                // Integral term accumulator
    double previous_error;          // Previous error for derivative calculation
    double last_update_time;        // Monotonic time of last update (seconds)
    
    // Current window counters (reset every window_size seconds)
    // Using uint64_t to prevent overflow with high request rates
    uint64_t window_start_time;     // When current window started (seconds)
    uint64_t window_success;        // Success count in current window
    uint64_t window_error;          // Error count in current window
    uint64_t window_rejected;       // Rejected count in current window
    
    // Ping counters (for ungated health checks)
    uint64_t window_ping_success;   // Successful pings in current window
    uint64_t window_ping_failure;   // Failed pings in current window
    
    // Last calculated rates (used between updates)
    double last_error_rate;         // Last calculated error rate
    double last_ping_failure_rate;  // Last calculated ping failure rate
    
    // Configuration (immutable after initialization)
    double kp;                      // Proportional gain
    double ki;                      // Integral gain  
    double kd;                      // Derivative gain
    double window_size;             // Window duration in seconds
    double target_error_rate;       // If > 0, overrides p90 calculation
    
    // Error rate history for p90 calculation (circular buffer)
    double error_rate_history[PID_HISTORY_SIZE];
    int history_index;              // Current index in circular buffer
    int history_count;              // Number of valid entries (0 to PID_HISTORY_SIZE)
    
    // Metadata
    int initialized;                // 1 if properly initialized, 0 otherwise
    pid_t creator_pid;              // PID of process that created this
} pid_controller_state_t;

/*
 * Ruby wrapper structure - one instance per process
 *
 * This structure is not shared - each process has its own copy
 * that points to the shared memory segment.
 */
typedef struct {
    int shm_id;                     // Shared memory segment ID
    key_t key;                      // IPC key (derived from resource name)
    char *name;                     // Resource name (for debugging)
    pid_controller_state_t *state;  // Pointer to shared memory segment
} semian_pid_controller_t;

// Forward declarations
void raise_semian_syscall_error(const char *syscall, int error_num);

/*
 * Initialize or attach to a shared PID controller
 *
 * This function either creates a new shared memory segment (if it doesn't exist)
 * or attaches to an existing one. The first process to create the segment is
 * responsible for initializing all fields.
 *
 * Parameters:
 *   pid: Pointer to pid controller structure to initialize
 *   name: Resource name (used to generate IPC key)
 *   permissions: Unix permissions for shared memory segment
 *   kp, ki, kd: PID controller gains
 *   window_size: Time window for rate calculations (seconds)
 *   target_error_rate: Target error rate (< 0 to use p90 calculation)
 */
void initialize_pid_controller(
    semian_pid_controller_t *pid,
    const char *name,
    long permissions,
    double kp,
    double ki,
    double kd,
    double window_size,
    double target_error_rate
);

/*
 * Record a request outcome
 *
 * Thread and process safe. Increments the appropriate counter
 * for the current window.
 *
 * Parameters:
 *   pid: PID controller
 *   outcome: "success", "error", or "rejected"
 */
void record_request_shared(semian_pid_controller_t *pid, const char *outcome);

/*
 * Record a ping outcome (ungated health check)
 *
 * Thread and process safe. Increments the appropriate ping counter
 * for the current window.
 *
 * Parameters:
 *   pid: PID controller
 *   outcome: "success" or "failure"
 */
void record_ping_shared(semian_pid_controller_t *pid, const char *outcome);

/*
 * Update the PID controller at the end of a time window
 *
 * This should be called once per window_size seconds. It:
 * 1. Calculates error and ping failure rates from current window
 * 2. Stores error rate in history
 * 3. Resets window counters
 * 4. Runs PID calculations
 * 5. Updates rejection_rate
 *
 * Thread and process safe, but typically called by only one process.
 *
 * Returns: Updated rejection_rate
 */
double update_pid_controller_shared(semian_pid_controller_t *pid);

/*
 * Check if a request should be rejected
 *
 * Thread and process safe. Compares a random number against
 * the current rejection_rate.
 *
 * Returns: 1 if request should be rejected, 0 otherwise
 */
int should_reject_shared(semian_pid_controller_t *pid);

/*
 * Get current rejection rate
 *
 * Thread and process safe.
 *
 * Returns: Current rejection_rate [0.0, 1.0]
 */
double get_rejection_rate_shared(semian_pid_controller_t *pid);

/*
 * Detach from shared memory
 *
 * Detaches the shared memory segment from this process's address space.
 * Does not remove the segment - other processes may still be using it.
 */
void destroy_pid_controller_shared(semian_pid_controller_t *pid);

/*
 * Remove shared memory segment
 *
 * Marks the shared memory segment for deletion. It will actually be
 * removed when the last process detaches.
 *
 * Should only be called by Semian.destroy, not by normal process cleanup.
 */
void remove_pid_controller_shm(semian_pid_controller_t *pid);

#endif // SEMIAN_PID_CONTROLLER_SHARED_H

