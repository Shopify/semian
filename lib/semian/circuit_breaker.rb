module Semian
  class CircuitBreaker #:nodoc:
    extend Forwardable

    def initialize(name, exceptions:, success_threshold:, error_threshold:, error_timeout:, permissions:, implementation:)
      @name = name.to_s
      @success_count_threshold = success_threshold
      @error_count_threshold = error_threshold
      @error_timeout = error_timeout
      @exceptions = exceptions

      @errors = implementation::SlidingWindow.new(max_size: @error_count_threshold,
                                                  name: "#{name}_sysv_sliding_window",
                                                  permissions: permissions)
      @successes = implementation::Integer.new(name: "#{name}_sysv_integer",
                                               permissions: permissions)
      @state = implementation::State.new(name: "#{name}_sysv_state",
                                         permissions: permissions)
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
      push_time(@errors, duration: @error_timeout)
      if closed?
        open if error_threshold_reached?
      elsif half_open?
        open
      end
    end

    def mark_success
      return unless half_open?
      @successes.increment
      close if success_threshold_reached?
    end

    def reset
      @errors.clear
      @successes.reset
      close
    end

    def destroy
      @errors.destroy
      @successes.destroy
      @state.destroy
    end

    private

    def_delegators :@state, :closed?, :open?, :half_open?
    private :closed?, :open?, :half_open?

    def close
      log_state_transition(:closed)
      @state.close
      @errors.clear
    end

    def open
      log_state_transition(:open)
      @state.open
    end

    def half_open
      log_state_transition(:half_open)
      @state.half_open
      @successes.reset
    end

    def success_threshold_reached?
      @successes.value >= @success_count_threshold
    end

    def error_threshold_reached?
      @errors.size == @error_count_threshold
    end

    def error_timeout_expired?
      time_ms = @errors.last
      time_ms && (Time.at(time_ms / 1000) + @error_timeout < Time.now)
    end

    def push_time(window, duration:, time: Time.now)
      @errors.execute_atomically do # Store an integer amount of milliseconds since epoch
        window.shift while window.first && window.first / 1000 + duration < time.to_i
        window << (time.to_f * 1000).to_i
      end
    end

    def log_state_transition(new_state)
      return if @state.nil? || new_state == @state.value

      str = "[#{self.class.name}] State transition from #{@state.value} to #{new_state}."
      str << " success_count=#{@successes.value} error_count=#{@errors.size}"
      str << " success_count_threshold=#{@success_count_threshold} error_count_threshold=#{@error_count_threshold}"
      str << " error_timeout=#{@error_timeout} error_last_at=\"#{@error_last_at}\""
      Semian.logger.info(str)
    end
  end
end
