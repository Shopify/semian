module Semian
  class ErrorRateCircuitBreaker #:nodoc:
    extend Forwardable

    def_delegators :@state, :closed?, :open?, :half_open?

    attr_reader :name, :half_open_resource_timeout, :error_timeout, :state, :last_error, :error_percent_threshold,
                :request_volume_threshold, :success_count_threshold

    def initialize(name, exceptions:, error_percent_threshold:, error_timeout:, window_size:,
                   request_volume_threshold:, success_threshold:, implementation:, half_open_resource_timeout: nil)

      raise 'error_threshold_percent should be between 0.0 and 1.0 exclusive' unless (0.0001...1.0).cover?(error_percent_threshold)

      @name = name.to_sym
      @error_timeout = error_timeout
      @exceptions = exceptions
      @half_open_resource_timeout = half_open_resource_timeout
      @error_percent_threshold = error_percent_threshold
      @last_error_time = nil
      @request_volume_threshold = request_volume_threshold
      @success_count_threshold = success_threshold

      @results = implementation::TimeSlidingWindow.new(window_size)
      @state = implementation::State.new

      reset
    end

    def acquire(resource = nil, &block)
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
      if closed?
        transition_to_open if error_threshold_reached?
      elsif half_open?
        transition_to_open
      end
    end

    def mark_success
      @results << true
      return unless half_open?
      transition_to_close if success_threshold_reached?
    end

    def reset
      @last_error_time = nil
      @results.clear
      transition_to_close
    end

    def destroy
      @state.destroy
    end

    # TODO understand what this is used for inside Semian lib
    def in_use?
      return false if error_timeout_expired?
      @results.count(false) > 0
    end

    private

    def current_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def transition_to_close
      notify_state_transition(:closed)
      log_state_transition(:closed)
      @state.close!
      @results.clear
    end

    def transition_to_open
      notify_state_transition(:open)
      log_state_transition(:open)
      @state.open!
    end

    def transition_to_half_open
      notify_state_transition(:half_open)
      log_state_transition(:half_open)
      @state.half_open!
      @results.clear
    end

    def success_threshold_reached?
      @results.count(true) >= @success_count_threshold
    end

    def error_threshold_reached?
      return false if @results.empty? or @results.length < @request_volume_threshold
      @results.count(false).to_f / @results.length.to_f >= @error_percent_threshold
    end

    def error_timeout_expired?
      return false unless @last_error_time
      current_time - @last_error_time >= @error_timeout
    end

    def push_error(error)
      @last_error = error
      @last_error_time = current_time
      @results << false
    end

    def log_state_transition(new_state)
      return if @state.nil? || new_state == @state.value

      str = "[#{self.class.name}] State transition from #{@state.value} to #{new_state}."
      str << " success_count=#{@results.count(true)} error_count=#{@results.count(false)}"
      str << " success_count_threshold=#{@success_count_threshold} error_count_percent=#{@error_percent_threshold}"
      str << " error_timeout=#{@error_timeout} error_last_at=\"#{@last_error_time}\""
      str << " name=\"#{@name}\""
      Semian.logger.info(str)
    end

    def notify_state_transition(new_state)
      Semian.notify(:state_change, self, nil, nil, state: new_state)
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
