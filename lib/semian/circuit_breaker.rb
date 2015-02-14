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

    def acquire(&block)
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

    def with_fallback(fallback, &block)
      acquire(&block)
    rescue *@exceptions
      evaluate_fallback(fallback)
    rescue OpenCircuitError
      evaluate_fallback(fallback)
    end

    def request_allowed?
      return true if closed?
      half_open if error_timeout_expired?
      !open?
    end

    def mark_failed(error)
      @errors.push(Time.new)

      if closed?
        open if @errors.size == @error_count_threshold
      elsif half_open?
        open
      end
    end

    def mark_success
      return unless half_open?
      @successes.push(Time.now)
      close if @successes.size == @success_threshold
    end

    def reset
      @errors    = SlidingTimeWindow.new(max_size: @error_count_threshold, duration: @error_timeout)
      @successes = SlidingTimeWindow.new(max_size: @success_threshold)

      close
    end

    private

    def evaluate_fallback(fallback_value_or_block)
      if fallback_value_or_block.respond_to?(:call)
        fallback_value_or_block.call
      else
        fallback_value_or_block
      end
    end

    def closed?
      state == :closed
    end

    def close
      log_state_transition(:closed)
      @state = :closed
      @error_count = 0
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
      @successes.clear
    end

    def error_timeout_expired?
      error_last_at = @errors.last
      error_last_at && (error_last_at + @error_timeout < Time.now)
    end

    def log_state_transition(new_state)
      return if @state.nil? || new_state == @state

      str = "[#{self.class.name}] State transition from #{@state} to #{new_state}."
      str << " success_count=#{@success_count} error_count=#{@error_count}"
      str << " success_count_threshold=#{@success_count_threshold} error_count_threshold=#{@error_count_threshold}"
      str << " error_timeout=#{@error_timeout} error_last_at=\"#{@error_last_at}\""
      Semian.logger.info(str)
    end
  end
end
