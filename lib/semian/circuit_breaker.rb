module Semian
  class CircuitBreaker
    extend Forwardable
    attr_reader :state

    def_delegators :@resource, :acquire, :destroy, :count, :semid

    def initialize(resource, exceptions:, success_threshold:, error_threshold:, error_timeout:)
      @resource = resource
      @success_count_threshold = success_threshold
      @error_count_threshold = error_threshold
      @error_timeout = error_timeout
      @exceptions = Array(exceptions) + [::Semian::BaseError]
      reset
    end

    def with_fallback(fallback, &block)
      return evaluate_fallback(fallback) unless request_allowed?

      result = nil
      begin
        result = acquire(&block)
      rescue *@exceptions => error
        mark_failed(error)
        result = evaluate_fallback(fallback)
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
      increment_recent_errors

      if closed?
        open if error_threshold_reached?
      elsif half_open?
        open
      end
    end

    def mark_success
      return unless half_open?
      @success_count += 1
      close if success_threshold_reached?
    end

    def reset
      @success_count = 0
      @error_count = 0
      @error_last_at = nil
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
      @success_count = 0
    end

    def increment_recent_errors
      if error_timeout_expired?
        @error_count = 0
      end

      @error_count += 1
      @error_last_at = Time.now
    end

    def success_threshold_reached?
      @success_count >= @success_count_threshold
    end

    def error_threshold_reached?
      @error_count >= @error_count_threshold
    end

    def error_timeout_expired?
      @error_last_at && (@error_last_at + @error_timeout < Time.now)
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