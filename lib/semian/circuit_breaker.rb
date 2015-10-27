module Semian
  class CircuitBreaker #:nodoc:
    def initialize(name, exceptions:, success_threshold:, error_threshold:, error_timeout:, permissions: 0660)
      @name = "#{name}"
      @success_count_threshold = success_threshold
      @error_count_threshold = error_threshold
      @error_timeout = error_timeout
      @exceptions = exceptions

      @sliding_window = ::Semian::SysVSlidingWindow.new(
        "#{name}_sliding_window",
        @error_count_threshold,
        permissions)
      @successes = ::Semian::SysVAtomicInteger.new(
        "#{name}_atomic_integer",
        permissions)
      @state = ::Semian::SysVAtomicEnum.new(
        "#{name}_atomic_enum",
        permissions,
        [:closed, :half_open, :open])
      # We do not need to #reset here since initializing is handled like this:
      # (0) if data is not shared, then it's zeroed already
      # (1) if no one is attached to the memory, zero it
      # (2) otherwise, keep the data
    end

    def shared?
      @sliding_window.shared? && @successes.shared? && @state.shared?
    end

    def state
      @state.value
    end

    def acquire
      raise OpenCircuitError unless request_allowed?

      result = nil
      begin
        result = yield
      rescue *@exceptions => error
        mark_failed(error)
        raise error
      else
        mark_success
      end
      result
    end

    def request_allowed?
      return true if closed?
      half_open if error_timeout_expired?
      !open?
    end

    def mark_failed(_error)
      push_time(@sliding_window, @error_count_threshold, duration: @error_timeout)
      if closed?
        open if error_threshold_reached?
      elsif half_open?
        open
      end
    end

    def mark_success
      return unless half_open?
      @successes.increase_by 1
      close if success_threshold_reached?
    end

    def reset
      @sliding_window.clear
      @successes.value = 0
      close
    end

    def destroy
      @sliding_window.destroy
      @successes.destroy
      @state.destroy
    end

    private

    def closed?
      @state.value == :closed
    end

    def close
      log_state_transition(:closed)
      @state.value = :closed
      @sliding_window.clear
    end

    def open?
      @state.value == :open
    end

    def open
      log_state_transition(:open)
      @state.value = :open
    end

    def half_open?
      @state.value == :half_open
    end

    def half_open
      log_state_transition(:half_open)
      @state.value = :half_open
      @successes.value = 0
    end

    def success_threshold_reached?
      @successes.value >= @success_count_threshold
    end

    def error_threshold_reached?
      @sliding_window.size == @error_count_threshold
    end

    def error_timeout_expired?
      time_ms = @sliding_window.last
      time_ms && (Time.at(time_ms / 1000) + @error_timeout < Time.now)
    end

    def push_time(window, max_size, duration:, time: Time.now)
      @sliding_window.execute_atomically do # Store an integer amount of milliseconds since epoch
        window.shift while window.first && Time.at(window.first / 1000) + duration < time
        window.shift if window.size == max_size
        window << (time.to_f * 1000).to_i
      end
    end

    def log_state_transition(new_state)
      return if @state.nil? || new_state == @state.value

      str = "[#{self.class.name}] State transition from #{@state.value} to #{new_state}."
      str << " success_count=#{@successes.value} error_count=#{@sliding_window.size}"
      str << " success_count_threshold=#{@success_count_threshold} error_count_threshold=#{@error_count_threshold}"
      str << " error_timeout=#{@error_timeout} error_last_at=\"#{@error_last_at}\""
      Semian.logger.info(str)
    end
  end
end
