/*
 * Ruby C Extension API for Shared PID Controller
 *
 * This file exposes the shared memory PID controller to Ruby as
 * the Semian::SharedPIDController class.
 */
#include <ruby.h>
#include "pid_controller_shared.h"

// Ruby class
static VALUE cSharedPIDController;

// Ruby data type for type-safe wrapping
static const rb_data_type_t semian_pid_controller_type;

/*
 * Allocate Ruby object
 */
static VALUE
semian_pid_controller_alloc(VALUE klass)
{
    semian_pid_controller_t *pid;
    VALUE obj = TypedData_Make_Struct(klass, semian_pid_controller_t,
                                     &semian_pid_controller_type, pid);
    pid->shm_id = -1;
    pid->state = NULL;
    pid->name = NULL;
    pid->key = 0;
    return obj;
}

/*
 * Initialize: new(name, kp, ki, kd, window_size, target_error_rate, permissions)
 *
 * @param name [String] Resource name
 * @param kp [Float] Proportional gain
 * @param ki [Float] Integral gain
 * @param kd [Float] Derivative gain
 * @param window_size [Float] Window duration in seconds
 * @param target_error_rate [Float] Target error rate (or -1 for p90)
 * @param permissions [Integer] Unix permissions (octal)
 * @return [SharedPIDController] Initialized controller
 */
static VALUE
semian_pid_controller_initialize(VALUE self, VALUE name, VALUE kp, VALUE ki,
                                 VALUE kd, VALUE window_size,
                                 VALUE target_error_rate, VALUE permissions)
{
    semian_pid_controller_t *pid;
    TypedData_Get_Struct(self, semian_pid_controller_t,
                        &semian_pid_controller_type, pid);
    
    // Extract and validate parameters
    Check_Type(name, T_STRING);
    const char *c_name = StringValueCStr(name);
    
    double c_kp = NUM2DBL(kp);
    double c_ki = NUM2DBL(ki);
    double c_kd = NUM2DBL(kd);
    double c_window_size = NUM2DBL(window_size);
    double c_target_error_rate = NUM2DBL(target_error_rate);
    long c_permissions = FIX2LONG(permissions);
    
    // Initialize shared memory
    initialize_pid_controller(pid, c_name, c_permissions,
                             c_kp, c_ki, c_kd, c_window_size,
                             c_target_error_rate);
    
    return self;
}

/*
 * Record request outcome: record_request(:success) / :error / :rejected
 *
 * @param outcome [Symbol] :success, :error, or :rejected
 * @return [nil]
 */
static VALUE
semian_pid_controller_record_request(VALUE self, VALUE outcome)
{
    semian_pid_controller_t *pid;
    TypedData_Get_Struct(self, semian_pid_controller_t,
                        &semian_pid_controller_type, pid);
    
    Check_Type(outcome, T_SYMBOL);
    const char *outcome_str = rb_id2name(SYM2ID(outcome));
    
    record_request_shared(pid, outcome_str);
    
    return Qnil;
}

/*
 * Record ping outcome: record_ping(:success) / :failure
 *
 * @param outcome [Symbol] :success or :failure
 * @return [nil]
 */
static VALUE
semian_pid_controller_record_ping(VALUE self, VALUE outcome)
{
    semian_pid_controller_t *pid;
    TypedData_Get_Struct(self, semian_pid_controller_t,
                        &semian_pid_controller_type, pid);
    
    Check_Type(outcome, T_SYMBOL);
    const char *outcome_str = rb_id2name(SYM2ID(outcome));
    
    record_ping_shared(pid, outcome_str);
    
    return Qnil;
}

/*
 * Update controller: update() -> returns new rejection_rate
 *
 * Should be called once per window to update the PID controller state.
 *
 * @return [Float] Updated rejection rate
 */
static VALUE
semian_pid_controller_update(VALUE self)
{
    semian_pid_controller_t *pid;
    TypedData_Get_Struct(self, semian_pid_controller_t,
                        &semian_pid_controller_type, pid);
    
    double rejection_rate = update_pid_controller_shared(pid);
    
    return DBL2NUM(rejection_rate);
}

/*
 * Check if should reject: should_reject? -> true/false
 *
 * @return [Boolean] true if request should be rejected
 */
static VALUE
semian_pid_controller_should_reject(VALUE self)
{
    semian_pid_controller_t *pid;
    TypedData_Get_Struct(self, semian_pid_controller_t,
                        &semian_pid_controller_type, pid);
    
    int should_reject = should_reject_shared(pid);
    
    return should_reject ? Qtrue : Qfalse;
}

/*
 * Get current rejection rate
 *
 * @return [Float] Current rejection rate [0.0, 1.0]
 */
static VALUE
semian_pid_controller_rejection_rate(VALUE self)
{
    semian_pid_controller_t *pid;
    TypedData_Get_Struct(self, semian_pid_controller_t,
                        &semian_pid_controller_type, pid);
    
    double rate = get_rejection_rate_shared(pid);
    
    return DBL2NUM(rate);
}

/*
 * Get metrics hash
 *
 * Returns a hash with all current metrics from the shared state.
 *
 * @return [Hash] Metrics hash
 */
static VALUE
semian_pid_controller_metrics(VALUE self)
{
    semian_pid_controller_t *pid;
    TypedData_Get_Struct(self, semian_pid_controller_t,
                        &semian_pid_controller_type, pid);
    
    // Lock and read all metrics
    lock_pid_mutex(&pid->state->lock);
    
    VALUE hash = rb_hash_new();
    
    rb_hash_aset(hash, ID2SYM(rb_intern("rejection_rate")),
                 DBL2NUM(pid->state->rejection_rate));
    rb_hash_aset(hash, ID2SYM(rb_intern("error_rate")),
                 DBL2NUM(pid->state->last_error_rate));
    rb_hash_aset(hash, ID2SYM(rb_intern("ping_failure_rate")),
                 DBL2NUM(pid->state->last_ping_failure_rate));
    rb_hash_aset(hash, ID2SYM(rb_intern("integral")),
                 DBL2NUM(pid->state->integral));
    rb_hash_aset(hash, ID2SYM(rb_intern("previous_error")),
                 DBL2NUM(pid->state->previous_error));
    
    // Current window requests
    VALUE current_window_requests = rb_hash_new();
    rb_hash_aset(current_window_requests, ID2SYM(rb_intern("success")),
                 ULL2NUM(pid->state->window_success));
    rb_hash_aset(current_window_requests, ID2SYM(rb_intern("error")),
                 ULL2NUM(pid->state->window_error));
    rb_hash_aset(current_window_requests, ID2SYM(rb_intern("rejected")),
                 ULL2NUM(pid->state->window_rejected));
    rb_hash_aset(hash, ID2SYM(rb_intern("current_window_requests")),
                 current_window_requests);
    
    // Current window pings
    VALUE current_window_pings = rb_hash_new();
    rb_hash_aset(current_window_pings, ID2SYM(rb_intern("success")),
                 ULL2NUM(pid->state->window_ping_success));
    rb_hash_aset(current_window_pings, ID2SYM(rb_intern("failure")),
                 ULL2NUM(pid->state->window_ping_failure));
    rb_hash_aset(hash, ID2SYM(rb_intern("current_window_pings")),
                 current_window_pings);
    
    unlock_pid_mutex(&pid->state->lock);
    
    return hash;
}

/*
 * Destroy/cleanup
 *
 * Detaches from shared memory. Does not remove the segment.
 */
static VALUE
semian_pid_controller_destroy(VALUE self)
{
    semian_pid_controller_t *pid;
    TypedData_Get_Struct(self, semian_pid_controller_t,
                        &semian_pid_controller_type, pid);
    
    destroy_pid_controller_shared(pid);
    
    return Qnil;
}

/*
 * Get shared memory ID (for debugging)
 *
 * @return [Integer] Shared memory segment ID
 */
static VALUE
semian_pid_controller_shm_id(VALUE self)
{
    semian_pid_controller_t *pid;
    TypedData_Get_Struct(self, semian_pid_controller_t,
                        &semian_pid_controller_type, pid);
    
    return INT2NUM(pid->shm_id);
}

/*
 * Cleanup function called by GC
 */
static void
semian_pid_controller_free(void *ptr)
{
    semian_pid_controller_t *pid = (semian_pid_controller_t *)ptr;
    
    // Detach from shared memory (but don't remove it)
    if (pid->state != NULL) {
        shmdt(pid->state);
        pid->state = NULL;
    }
    
    if (pid->name != NULL) {
        free(pid->name);
        pid->name = NULL;
    }
    
    xfree(pid);
}

/*
 * Return memory size for GC
 */
static size_t
semian_pid_controller_memsize(const void *ptr)
{
    return sizeof(semian_pid_controller_t);
}

/*
 * Ruby data type definition
 */
static const rb_data_type_t
semian_pid_controller_type = {
    "semian_shared_pid_controller",
    {
        NULL, // mark function (no Ruby objects to mark)
        semian_pid_controller_free,
        semian_pid_controller_memsize,
    },
    NULL, NULL,
    RUBY_TYPED_FREE_IMMEDIATELY | RUBY_TYPED_WB_PROTECTED
};

/*
 * Initialize the extension
 *
 * This is called when the semian extension is loaded.
 * It defines the Semian::SharedPIDController class and its methods.
 */
void
Init_shared_pid_controller(void)
{
    // Get Semian module (should already be defined)
    VALUE mSemian = rb_define_module("Semian");
    
    // Define Semian::SharedPIDController class
    cSharedPIDController = rb_define_class_under(mSemian,
                                                 "SharedPIDController",
                                                 rb_cObject);
    
    // Set allocator
    rb_define_alloc_func(cSharedPIDController, semian_pid_controller_alloc);
    
    // Define methods
    rb_define_method(cSharedPIDController, "initialize",
                     semian_pid_controller_initialize, 7);
    rb_define_method(cSharedPIDController, "record_request",
                     semian_pid_controller_record_request, 1);
    rb_define_method(cSharedPIDController, "record_ping",
                     semian_pid_controller_record_ping, 1);
    rb_define_method(cSharedPIDController, "update",
                     semian_pid_controller_update, 0);
    rb_define_method(cSharedPIDController, "should_reject?",
                     semian_pid_controller_should_reject, 0);
    rb_define_method(cSharedPIDController, "rejection_rate",
                     semian_pid_controller_rejection_rate, 0);
    rb_define_method(cSharedPIDController, "metrics",
                     semian_pid_controller_metrics, 0);
    rb_define_method(cSharedPIDController, "destroy",
                     semian_pid_controller_destroy, 0);
    rb_define_method(cSharedPIDController, "shm_id",
                     semian_pid_controller_shm_id, 0);
}

