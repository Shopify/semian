# frozen_string_literal: true

require "thread"

module Semian
  # PID (Proportional-Integral-Derivative) Circuit Breaker with Partial Opening
  #
  # This circuit breaker uses a PID controller algorithm with a unique approach:
  # instead of binary open/closed states, it partially throttles requests based
  # on the proportional (P) term. The circuit can reject 0-100% of requests
  # based on current stress levels.
  #
  # Features:
  # - Partial blocking: Rejects a percentage of requests based on P value
  # - Periodic health pings: Monitors service health proactively
  # - Adaptive throttling: Smoothly adjusts rejection rate based on conditions
  #
  # The PID controller calculates stress based on:
  # - Error rate from actual requests
  # - Difference between rejection rate and ping success rate
  # - Historical error accumulation (I term)
  # - Rate of change in errors (D term)
  class PIDCircuitBreaker
    attr_reader(
      :name,
      :half_open_resource_timeout,
      :error_timeout,
      :last_error,
      :pid_output,
      :error_rate_setpoint,
      :rejection_rate,
      :ping_success_rate,
      :p_value,
      :i_value,
      :d_value,
    )

    # Initialize a new PID Circuit Breaker with Partial Opening
    #
    # @param name [String, Symbol] Name of the circuit breaker
    # @param exceptions [Array<Class>] Array of exception classes to track as errors
    # @param error_timeout [Float] Not used in this implementation (kept for compatibility)
    # @param implementation [Module] Implementation module (Simple or ThreadSafe)
    # @param half_open_resource_timeout [Float, nil] Timeout for resources
    # @param pid_kp [Float] Proportional gain coefficient (default: 1.0)
    # @param pid_ki [Float] Integral gain coefficient (default: 0.1)
    # @param pid_kd [Float] Derivative gain coefficient (default: 0.05)
    # @param error_rate_setpoint [Float] Target error rate (0.0 to 1.0, default: 0.05)
    # @param sample_window_size [Integer] Number of recent requests to track (default: 100)
    # @param min_requests [Integer] Minimum requests before evaluating circuit (default: 10)
    # @param ping_interval [Float] Seconds between health check pings (default: 1.0)
    # @param ping_timeout [Float] Timeout for ping requests in seconds (default: 0.5)
    # @param ping_weight [Float] Weight of ping results in P calculation (default: 0.3)
    # @param max_rejection_rate [Float] Maximum rejection rate (0.0 to 1.0, default: 0.95)
    def initialize(name, exceptions:, error_timeout:, implementation:,
      half_open_resource_timeout: nil,
      pid_kp: 1.0, pid_ki: 0.1, pid_kd: 0.05,
      error_rate_setpoint: 0.05,
      sample_window_size: 100, min_requests: 10,
      ping_interval: 1.0, ping_timeout: 0.5, ping_weight: 0.3,
      max_rejection_rate: 0.95, **options)
      @name = name.to_sym
      @exceptions = exceptions
      @error_timeout = error_timeout # Kept for compatibility but not used
      @half_open_resource_timeout = half_open_resource_timeout

      # PID controller parameters
      @pid_kp = pid_kp  # Proportional gain
      @pid_ki = pid_ki  # Integral gain
      @pid_kd = pid_kd  # Derivative gain

      # Control parameters
      @error_rate_setpoint = error_rate_setpoint # Target error rate
      @min_requests = min_requests # Minimum requests before evaluation
      @max_rejection_rate = max_rejection_rate # Cap rejection rate

      # Ping configuration
      @ping_interval = ping_interval
      @ping_timeout = ping_timeout
      @ping_weight = ping_weight # How much ping results affect P term (0.0 to 1.0)
      @ping_proc = nil # User-provided ping implementation
      @last_ping_time = nil
      @ping_thread = nil
      @ping_mutex = Mutex.new

      # State tracking
      @request_window = implementation::SlidingWindow.new(max_size: sample_window_size)
      @ping_results = implementation::SlidingWindow.new(max_size: 20) # Track last 20 pings
      @rejection_window = implementation::SlidingWindow.new(max_size: sample_window_size)

      # PID controller state
      @integral_error = 0.0
      @last_error_rate = 0.0
      @last_calculation_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @pid_output = 0.0
      @p_value = 0.0
      @i_value = 0.0
      @d_value = 0.0

      # Current rejection rate (0.0 to 1.0)
      @rejection_rate = 0.0
      @ping_success_rate = 1.0

      # Track timing of last error
      @last_error_time = nil

      # Synchronization
      @calculation_mutex = implementation == ::Semian::ThreadSafe ? Mutex.new : nil

      reset
    end

    # Configure the ping implementation
    # @param block [Proc] A block that performs a health check ping
    #   Should return true for success, false for failure
    #   Should complete within ping_timeout or will be considered failed
    def configure_ping(&block)
      @ping_proc = block
      start_ping_thread if @ping_proc
    end

    def acquire(resource = nil, &block)
      # Decide whether to reject this request based on current rejection rate
      if should_reject_request?
        # Track this as a rejection
        @rejection_window << true
        raise OpenCircuitError, "Request rejected by PID circuit breaker (rejection rate: #{(@rejection_rate * 100).round(1)}%)"
      else
        @rejection_window << false
      end

      result = nil
      begin
        result = maybe_with_resource_timeout(resource, &block)
        mark_success
      rescue *@exceptions => error
        if !error.respond_to?(:marks_semian_circuits?) || error.marks_semian_circuits?
          mark_failed(error)
        end
        raise error
      end
      result
    end

    def mark_failed(error)
      @last_error = error
      @last_error_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      # Track request outcome (false = failure)
      @request_window << false

      # Recalculate PID output and rejection rate
      calculate_pid_output
      update_rejection_rate
    end

    def mark_success
      # Track request outcome (true = success)
      @request_window << true

      # Recalculate PID output to potentially reduce rejection rate
      calculate_pid_output
      update_rejection_rate
    end

    def reset
      @request_window.clear
      @rejection_window.clear
      @ping_results.clear
      @integral_error = 0.0
      @last_error_rate = 0.0
      @pid_output = 0.0
      @p_value = 0.0
      @i_value = 0.0
      @d_value = 0.0
      @rejection_rate = 0.0
      @ping_success_rate = 1.0
      @last_error_time = nil
      stop_ping_thread
      start_ping_thread if @ping_proc
    end

    def destroy
      stop_ping_thread
      @request_window.destroy
      @rejection_window.destroy
      @ping_results.destroy
    end

    def in_use?
      @request_window.size > 0 || @rejection_window.size > 0
    end

    # Get current error rate from the request window
    def current_error_rate
      return 0.0 if @request_window.empty?

      failures = 0
      total = 0

      # Count failures and total requests
      @request_window.instance_variable_get(:@window).each do |outcome|
        total += 1
        failures += 1 unless outcome
      end

      return 0.0 if total == 0

      failures.to_f / total
    end

    # Get current rejection rate from the rejection window
    def current_rejection_rate
      return 0.0 if @rejection_window.empty?

      rejections = 0
      total = 0

      @rejection_window.instance_variable_get(:@window).each do |rejected|
        total += 1
        rejections += 1 if rejected
      end

      return 0.0 if total == 0

      rejections.to_f / total
    end

    # Check if circuit is effectively closed (not rejecting requests)
    def closed?
      @rejection_rate < 0.01 # Less than 1% rejection
    end

    # Check if circuit is partially open (rejecting some requests)
    def partially_open?
      @rejection_rate > 0.01 && @rejection_rate < 0.99
    end

    # Check if circuit is effectively open (rejecting most requests)
    def open?
      @rejection_rate >= 0.99 # 99% or more rejection
    end

    # For compatibility, these always return false since we don't have traditional states
    def half_open?
      false
    end

    def transition_to_half_open?
      false
    end

    def request_allowed?
      !should_reject_request?
    end

    private

    def calculate_pid_output
      if @calculation_mutex
        @calculation_mutex.synchronize { calculate_pid_output_unsafe }
      else
        calculate_pid_output_unsafe
      end
    end

    def calculate_pid_output_unsafe
      return if @request_window.size < @min_requests && @ping_results.empty?

      current_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      dt = current_time - @last_calculation_time
      @last_calculation_time = current_time

      # Calculate current error from request error rate
      error_rate = current_error_rate
      error = error_rate - @error_rate_setpoint

      # Calculate ping success rate
      update_ping_success_rate

      # Proportional term includes both error rate and ping/rejection difference
      # The ping/rejection difference helps the circuit adapt based on health checks
      rejection_diff = current_rejection_rate - @ping_success_rate

      # P term combines error rate and ping/rejection difference
      # If we're rejecting more than ping success rate suggests, reduce P
      # If ping success is high but we're rejecting a lot, reduce rejection
      @p_value = @pid_kp * (error + @ping_weight * rejection_diff)

      # Integral term (accumulate error over time)
      @integral_error += error * dt
      # Prevent integral windup
      @integral_error = [[@integral_error, -10.0].max, 10.0].min
      @i_value = @pid_ki * @integral_error

      # Derivative term (rate of change)
      @d_value = 0.0
      if dt > 0
        error_rate_change = (error_rate - @last_error_rate) / dt
        @d_value = @pid_kd * error_rate_change
      end
      @last_error_rate = error_rate

      # Calculate PID output
      @pid_output = @p_value + @i_value + @d_value

      log_pid_calculation(error_rate, error, @p_value, @i_value, @d_value, rejection_diff)
    end

    def update_rejection_rate
      # Use the P value directly as rejection rate
      # P value represents the proportional response to current conditions
      # Clamp between 0 and max_rejection_rate
      @rejection_rate = [[@p_value, 0.0].max, @max_rejection_rate].min

      # Smooth the rejection rate to avoid sudden changes
      if @rejection_window.size > 0
        # Apply exponential moving average for smoother transitions
        alpha = 0.3 # Smoothing factor
        @rejection_rate = alpha * @rejection_rate + (1 - alpha) * current_rejection_rate
        @rejection_rate = [[@rejection_rate, 0.0].max, @max_rejection_rate].min
      end

      log_rejection_update
    end

    def should_reject_request?
      # Probabilistically reject based on rejection rate
      rand < @rejection_rate
    end

    def update_ping_success_rate
      return if @ping_results.empty?

      successes = 0
      total = 0

      @ping_results.instance_variable_get(:@window).each do |success|
        total += 1
        successes += 1 if success
      end

      @ping_success_rate = total > 0 ? successes.to_f / total : 1.0
    end

    def start_ping_thread
      return unless @ping_proc

      @ping_thread = Thread.new do
        loop do
          sleep(@ping_interval)
          perform_ping
        rescue => e
          Semian.logger.error("[#{self.class.name}] Ping thread error: #{e.message}")
        end
      end
    end

    def stop_ping_thread
      if @ping_thread
        @ping_thread.kill
        @ping_thread = nil
      end
    end

    def perform_ping
      return unless @ping_proc

      success = false
      begin
        # Execute ping with timeout
        success = Timeout.timeout(@ping_timeout) do
          @ping_proc.call
        end
      rescue Timeout::Error
        success = false
      rescue => e
        success = false
        Semian.logger.debug("[#{self.class.name}] Ping failed: #{e.message}")
      end

      @ping_mutex.synchronize do
        @ping_results << success
        @last_ping_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # Recalculate after ping
      calculate_pid_output
      update_rejection_rate

      log_ping_result(success)
    end

    def log_pid_calculation(error_rate, error, p_term, i_term, d_term, rejection_diff)
      return unless ENV["SEMIAN_DEBUG_PID"]

      str = "[#{self.class.name}] PID calculation:"
      str += " error_rate=#{(error_rate * 100).round(2)}%"
      str += " error=#{error.round(4)}"
      str += " rejection_diff=#{rejection_diff.round(4)}"
      str += " P=#{p_term.round(4)}"
      str += " I=#{i_term.round(4)}"
      str += " D=#{d_term.round(4)}"
      str += " output=#{@pid_output.round(4)}"
      str += " name=\"#{@name}\""

      Semian.logger.debug(str)
    end

    def log_rejection_update
      return unless ENV["SEMIAN_DEBUG_PID"]

      str = "[#{self.class.name}] Rejection rate updated:"
      str += " rate=#{(@rejection_rate * 100).round(1)}%"
      str += " p_value=#{@p_value.round(4)}"
      str += " ping_success=#{(@ping_success_rate * 100).round(1)}%"
      str += " name=\"#{@name}\""

      Semian.logger.debug(str)
    end

    def log_ping_result(success)
      return unless ENV["SEMIAN_DEBUG_PID"]

      str = "[#{self.class.name}] Ping result:"
      str += " success=#{success}"
      str += " ping_success_rate=#{(@ping_success_rate * 100).round(1)}%"
      str += " name=\"#{@name}\""

      Semian.logger.debug(str)
    end

    def maybe_with_resource_timeout(resource, &block)
      if @half_open_resource_timeout && resource.respond_to?(:with_resource_timeout)
        resource.with_resource_timeout(@half_open_resource_timeout) do
          block.call
        end
      else
        block.call
      end
    end
  end
end
