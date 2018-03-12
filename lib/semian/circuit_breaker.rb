module Semian
  class CircuitBreaker #:nodoc:
    extend Forwardable

    def_delegators :@state, :closed?, :open?, :half_open?

    attr_reader :name

    def initialize(name, exceptions:, success_threshold:, error_threshold:, error_timeout:, implementation:)
      @name = name.to_sym
      @success_count_threshold = success_threshold
      @error_count_threshold = error_threshold
      @error_timeout = error_timeout
      @exceptions = exceptions

      @errors = implementation::SlidingWindow.new(max_size: @error_count_threshold)
      @successes = implementation::Integer.new
      @state = implementation::State.new
    end

    def acquire
      return yield if disabled?

      half_open if open? && error_timeout_expired?

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
      closed? ||
        half_open? ||
        # The circuit breaker is officially open, but it will transition to half-open on the next attempt.
        (open? && error_timeout_expired?)
    end

    def mark_failed(_error)
      push_time(@errors)
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
      last_error_time = @errors.last
      return false unless last_error_time
      Time.at(last_error_time) + @error_timeout < Time.now
    end

    def push_time(window, time: Time.now)
      window.reject! { |err_time| err_time + @error_timeout < time.to_i }
      window << time.to_i
    end

    def log_state_transition(new_state)
      return if @state.nil? || new_state == @state.value

      str = "[#{self.class.name}] State transition from #{@state.value} to #{new_state}."
      str << " success_count=#{@successes.value} error_count=#{@errors.size}"
      str << " success_count_threshold=#{@success_count_threshold} error_count_threshold=#{@error_count_threshold}"
      str << " error_timeout=#{@error_timeout} error_last_at=\"#{@errors.last}\""
      Semian.logger.info(str)
    end

    def disabled?
      ENV['SEMIAN_CIRCUIT_BREAKER_DISABLED'] || ENV['SEMIAN_DISABLED']
    end
  end
end
