module Semian
  class CircuitBreaker
    attr_reader :state

    def initialize(name, exceptions:, success_threshold:, error_threshold:, error_timeout:, permissions: 0660)
      @name = "#{name}_circuit_breaker"
      @success_count_threshold = success_threshold
      @error_count_threshold = error_threshold
      @error_timeout = error_timeout
      @exceptions = exceptions

      @shared_circuit_breaker_data = ::Semian::SlidingWindow.new(
        @name,
        @error_count_threshold,
        permissions)
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

    def mark_failed(error)
      push_time(@shared_circuit_breaker_data, @error_count_threshold, duration: @error_timeout)
      if closed?
        open if error_threshold_reached?
      elsif half_open?
        open
      end
    end

    def mark_success
      return unless half_open?
      @shared_circuit_breaker_data.successes += 1
      close if success_threshold_reached?
    end

    def reset
      @shared_circuit_breaker_data.clear
      @shared_circuit_breaker_data.successes=0
    end

    private

    def closed?
      state == :closed
    end

    def close
      log_state_transition(:closed)
      @state = :closed
      @shared_circuit_breaker_data.clear
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
      @shared_circuit_breaker_data.successes=0
    end

    def success_threshold_reached?
      @shared_circuit_breaker_data.successes >= @success_count_threshold
    end

    def error_threshold_reached?
      @shared_circuit_breaker_data.size == @error_count_threshold
    end

    def error_timeout_expired?
      time_ms = @shared_circuit_breaker_data.last
      time_ms && (Time.at(time_ms/1000) + @error_timeout < Time.now)
    end

    def push_time(window, max_size, duration:, time: Time.now)
      window.shift while window.first && Time.at(window.first/1000) + duration < time
      window.shift if window.size == max_size
      window << (time.to_f*1000).to_i
    end

    def log_state_transition(new_state)
      return if @state.nil? || new_state == @state

      str = "[#{self.class.name}] State transition from #{@state} to #{new_state}."
      str << " success_count=#{@shared_circuit_breaker_data.successes} error_count=#{@shared_circuit_breaker_data.size}"
      str << " success_count_threshold=#{@success_count_threshold} error_count_threshold=#{@error_count_threshold}"
      str << " error_timeout=#{@error_timeout} error_last_at=\"#{@error_last_at}\""
      Semian.logger.info(str)
    end
  end
end
