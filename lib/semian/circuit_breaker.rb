module Semian
  class CircuitBreaker #:nodoc:
    def initialize(name, exceptions:, success_threshold:, error_threshold:, error_timeout:, type_namespace:)
      @name = name.to_s
      @success_count_threshold = success_threshold
      @error_count_threshold = error_threshold
      @error_timeout = error_timeout
      @exceptions = exceptions

      @errors = type_namespace::SlidingWindow.new(max_size: @error_count_threshold)
      @successes = type_namespace::Integer.new
      @state = type_namespace::Enum.new(symbol_list: [:closed, :half_open, :open])
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
      @successes.value = 0
      close
    end

    def destroy
      @errors.destroy
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
      @errors.clear
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
      @errors.size == @error_count_threshold
    end

    def error_timeout_expired?
      time_ms = @errors.last
      time_ms && (Time.at(time_ms / 1000) + @error_timeout < Time.now)
    end

    def push_time(window, duration:, time: Time.now)
      # The sliding window stores the integer amount of milliseconds since epoch as a timestamp
      window.shift while window.first && Time.at(window.first / 1000) + duration < time
      window << (time.to_f * 1000).to_i
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
