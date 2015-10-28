module Semian
  class CircuitBreaker
    attr_reader :state

    def initialize(exceptions:, success_threshold:, error_threshold:, error_timeout:)
      @success_count_threshold = success_threshold
      @error_count_threshold = error_threshold
      @error_timeout = error_timeout
      @exceptions = exceptions
      reset
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
      push_time(@errors, @error_count_threshold, duration: @error_timeout)

      if closed?
        open if error_threshold_reached?
      elsif half_open?
        open
      end
    end

    def mark_success
      return unless half_open?
      @successes += 1
      close if success_threshold_reached?
    end

    def reset
      @errors = []
      @successes = 0
      close
    end

    private

    def closed?
      state == :closed
    end

    def close
      log_state_transition(:closed)
      @state = :closed
      @errors = []
    end

    def open?
      state == :open
    end

    def open
      log_state_transition(:open)
      @state = :open
    end

    def half_open?
      state == :half_open
    end

    def half_open
      log_state_transition(:half_open)
      @state = :half_open
      @successes = 0
    end

    def success_threshold_reached?
      @successes >= @success_count_threshold
    end

    def error_threshold_reached?
      @errors.count == @error_count_threshold
    end

    def error_timeout_expired?
      @errors.last && (@errors.last + @error_timeout < Time.now)
    end

    def push_time(window, max_size, duration:, time: Time.now)
      window.shift while window.first && window.first + duration < time
      window.shift if window.size == max_size
      window << time
    end

    def log_state_transition(new_state)
      return if @state.nil? || new_state == @state

      str = "[#{self.class.name}] State transition from #{@state} to #{new_state}."
      str << " success_count=#{@successes} error_count=#{@errors.count}"
      str << " success_count_threshold=#{@success_count_threshold} error_count_threshold=#{@error_count_threshold}"
      str << " error_timeout=#{@error_timeout} error_last_at=\"#{@error_last_at}\""
      Semian.logger.info(str)
    end
  end
end
