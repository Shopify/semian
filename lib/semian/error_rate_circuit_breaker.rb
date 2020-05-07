module Semian
  class ErrorRateCircuitBreaker #:nodoc:
    extend Forwardable

    def_delegators :@state, :closed?, :open?, :half_open?

    attr_reader :name, :half_open_resource_timeout, :error_timeout, :state, :last_error, :error_percent_threshold,
                :minimum_request_volume, :success_threshold, :exceptions

    def_delegator :@window, :time_window_ms

    def initialize(name, exceptions:, error_percent_threshold:, error_timeout:, time_window:,
      minimum_request_volume:, success_threshold:, implementation:,
      half_open_resource_timeout: nil, time_source: nil)

      raise 'error_threshold_percent should be between 0.0 and 1.0 exclusive' unless 0 < error_percent_threshold && error_percent_threshold < 1

      @name = name.to_sym
      @error_timeout = error_timeout
      @exceptions = exceptions
      @half_open_resource_timeout = half_open_resource_timeout
      @error_percent_threshold = error_percent_threshold
      @last_error_time = nil
      @minimum_request_volume = minimum_request_volume
      @success_threshold = success_threshold
      @time_source = time_source ? time_source : -> { Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond) }
      @window = implementation::TimeSlidingWindow.new(time_window, @time_source)
      @state = implementation::State.new

      reset
    end

    def acquire(resource = nil, &block)
      return yield if disabled?
      transition_to_half_open if transition_to_half_open?

      raise OpenCircuitError unless request_allowed?

      time_start = current_time
      result = nil
      begin
        result = maybe_with_half_open_resource_timeout(resource, &block)
      rescue *@exceptions => error
        if !error.respond_to?(:marks_semian_circuits?) || error.marks_semian_circuits?
          mark_failed(error, current_time - time_start)
        end
        raise error
      else
        mark_success(current_time - time_start)
      end
      result
    end

    def transition_to_half_open?
      open? && error_timeout_expired? && !half_open?
    end

    def request_allowed?
      closed? || half_open? || transition_to_half_open?
    end

    def mark_failed(error, time_spent)
      push_error(error, time_spent)
      if closed?
        transition_to_open if error_threshold_reached?
      elsif half_open?
        transition_to_open
      end
    end

    def mark_success(time_spent)
      @window << [true, time_spent]
      return unless half_open?
      transition_to_close if success_threshold_reached?
    end

    def reset
      @last_error_time = nil
      @window.clear
      transition_to_close
    end

    def destroy
      @state.destroy
    end

    def in_use?
      return false if error_timeout_expired?
      error_count > 0
    end

    private

    def current_time
      @time_source.call
    end

    def transition_to_close
      notify_state_transition(:closed)
      log_state_transition(:closed)
      @state.close!
    end

    def transition_to_open
      notify_state_transition(:open)
      log_state_transition(:open)
      @state.open!
      @window.clear
    end

    def transition_to_half_open
      notify_state_transition(:half_open)
      log_state_transition(:half_open)
      @state.half_open!
      @window.clear
    end

    def success_threshold_reached?
      success_count >= @success_threshold
    end

    def error_threshold_reached?
      return false if @window.empty? || @window.length < @minimum_request_volume
      success_time_spent, error_time_spent = calculate_time_spent
      total_time = error_time_spent + success_time_spent
      error_time_spent / total_time >= @error_percent_threshold
    end

    def calculate_time_spent
      @window.each_with_object([0.0, 0.0]) do |entry, sum|
        if entry[0] == true
          sum[0] = entry[1] + sum[0]
        else
          sum[1] = entry[1] + sum[1]
        end
      end
    end

    def error_count
      @window.count { |entry| entry[0] == false }.to_f
    end

    def success_count
      @window.count { |entry| entry[0] == true }.to_f
    end

    def error_timeout_expired?
      return false unless @last_error_time
      current_time - @last_error_time >= @error_timeout * 1000
    end

    def push_error(error, time_spent)
      @last_error = error
      @last_error_time = current_time
      @window << [false, time_spent]
    end

    def log_state_transition(new_state)
      return if @state.nil? || new_state == @state.value

      str = "[#{self.class.name}] State transition from #{@state.value} to #{new_state}."
      str << " success_count=#{success_count} error_count=#{error_count}"
      str << " success_count_threshold=#{@success_threshold} error_count_percent=#{@error_percent_threshold}"
      str << " error_timeout=#{@error_timeout} error_last_at=\"#{@last_error_time}\""
      str << " minimum_request_volume=#{@minimum_request_volume} time_window_ms=#{@window.time_window_ms}"
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
