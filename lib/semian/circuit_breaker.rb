module Semian
  class CircuitBreaker #:nodoc:
    extend Forwardable

    def_delegators :@state, :closed?, :open?, :half_open?

    attr_reader :name, :half_open_resource_timeout, :error_timeout, :state, :last_error

    def initialize(name, exceptions:, success_threshold:, error_threshold:, error_timeout:, implementation:, half_open_resource_timeout: nil)
      @name = name.to_sym
      initialize_circuit_breaker(@name)

      @success_count_threshold = success_threshold
      @error_count_threshold = error_threshold
      @error_timeout = error_timeout
      @exceptions = exceptions
      @half_open_resource_timeout = half_open_resource_timeout

      @errors = implementation::SlidingWindow.new("#{name}_window", max_size: @error_count_threshold)
      @successes = implementation::Integer.new("#{name}_successes")
      state_val = implementation::Integer.new("#{name}_state")
      @state = implementation::State.new(state_val)
    end

    def acquire(resource = nil, &block)
      puts "[DEBUG] #{Time.now} - Acquiring resource '#{resource}'"

      return yield if disabled?
      transition_to_half_open if transition_to_half_open?

      raise OpenCircuitError unless request_allowed?

      result = nil
      begin
        result = maybe_with_half_open_resource_timeout(resource, &block)
      rescue *@exceptions => error
        if !error.respond_to?(:marks_semian_circuits?) || error.marks_semian_circuits?
          mark_failed(error)
        end
        raise error
      else
        mark_success
      end
      result
    end

    def transition_to_half_open?
      open? && error_timeout_expired? && !half_open?
    end

    def request_allowed?
      closed? || half_open? || transition_to_half_open?
    end

    def mark_failed(error)
      push_error(error)
      push_time(@errors)
      if closed?
        transition_to_open if error_threshold_reached?
      elsif half_open?
        transition_to_open
      end
    end

    def mark_success
      return unless half_open?
      @successes.increment(1)
      transition_to_close if success_threshold_reached?
    end

    def reset
      @errors.clear
      @successes.reset
      transition_to_close
    end

    def destroy
      @errors.destroy
      @successes.destroy
      @state.destroy
    end

    def in_use?
      return false if error_timeout_expired?
      @errors.size > 0
    end

    private

    def transition_to_close
      log_state_transition(:closed)
      @state.close!
      @errors.clear
    end

    def transition_to_open
      log_state_transition(:open)
      @state.open!
    end

    def transition_to_half_open
      log_state_transition(:half_open)
      @state.half_open!
      @successes.reset
    end

    def success_threshold_reached?
      @successes.value >= @success_count_threshold
    end

    def error_threshold_reached?
      @errors.size == @error_count_threshold
    end

    def error_timeout_expired?
      puts "[DEBUG] Checking error_timeout_expired? #{@errors.last}"
      last_error_time = @errors.last
      return false unless last_error_time
      Time.at(last_error_time) + @error_timeout < Time.now
    end

    def push_error(error)
      @last_error = error
    end

    def push_time(window, time: Time.now)
      puts "[DEBUG] push_time(#{time.to_i}) - rejecting before #{time.to_i - @error_timeout}"
      window.reject! { |err_time| err_time + @error_timeout < time.to_i }
      window << time.to_i
    end

    def log_state_transition(new_state)
      return if @state.nil? || new_state == @state.value

      str = "[#{self.class.name}] State transition from #{@state} to #{new_state}."
      str << " success_count=#{@successes.value} error_count=#{@errors.size}"
      str << " success_count_threshold=#{@success_count_threshold} error_count_threshold=#{@error_count_threshold}"
      str << " error_timeout=#{@error_timeout} error_last_at=\"#{@errors.last}\""
      Semian.logger.info(str)
    end

    def disabled?
      ENV['SEMIAN_CIRCUIT_BREAKER_DISABLED'] || ENV['SEMIAN_DISABLED']
    end

    def maybe_with_half_open_resource_timeout(resource, &block)
      result =
        if half_open? && @half_open_resource_timeout && resource.respond_to?(:with_resource_timeout)
          resource.with_resource_timeout(@half_open_resource_timeout) do
            block.call
          end
        else
          block.call
        end

      result
    end
  end
end
