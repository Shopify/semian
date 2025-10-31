# frozen_string_literal: true

require_relative "circuit_breaker_behaviour"

module Semian
  class CircuitBreaker # :nodoc:
    include CircuitBreakerBehaviour
    extend Forwardable

    def_delegators :@state, :closed?, :open?, :half_open?

    attr_reader(
      :half_open_resource_timeout,
      :error_timeout,
      :state,
      :error_threshold_timeout_enabled,
    )

    def initialize(name, exceptions:, success_threshold:, error_threshold:,
      error_timeout:, implementation:, half_open_resource_timeout: nil,
      error_threshold_timeout: nil, error_threshold_timeout_enabled: true,
      lumping_interval: 0)
      initialize_behaviour(name: name)

      @exceptions = exceptions
      @success_count_threshold = success_threshold
      @error_count_threshold = error_threshold
      @error_threshold_timeout = error_threshold_timeout || error_timeout
      @error_threshold_timeout_enabled = error_threshold_timeout_enabled.nil? ? true : error_threshold_timeout_enabled
      @error_timeout = error_timeout
      @half_open_resource_timeout = half_open_resource_timeout
      @lumping_interval = lumping_interval

      @errors = implementation::SlidingWindow.new(max_size: @error_count_threshold)
      @successes = implementation::Integer.new
      @state = implementation::State.new

      reset
    end

    def acquire(resource = nil, &block)
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
      return unless half_open?

      @successes.increment
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
      !error_timeout_expired? && !@errors.empty?
    end

    private

    def transition_to_close
      notify_state_transition(:closed)
      log_state_transition(:closed)
      @state.close!
      @errors.clear
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

      last_error_time + @error_timeout < Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def push_error(error)
      time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      if error_threshold_timeout_enabled
        @errors.reject! { |err_time| err_time + @error_threshold_timeout < time }
      end

      if @errors.empty? || @errors.last <= time - @lumping_interval
        @last_error = error
        @errors << time
      end
    end

    def log_state_transition(new_state)
      return if @state.nil? || new_state == @state.value

      str = "[#{self.class.name}] State transition from #{@state.value} to #{new_state}."
      str += " success_count=#{@successes.value} error_count=#{@errors.size}"
      str += " success_count_threshold=#{@success_count_threshold}"
      str += " error_count_threshold=#{@error_count_threshold}"
      str += " error_timeout=#{@error_timeout} error_last_at=\"#{@errors.last}\""
      str += " name=\"#{@name}\""
      if new_state == :open && @last_error
        str += " last_error_message=#{@last_error.message.inspect}"
      end

      Semian.logger.info(str)
    end

    def notify_state_transition(new_state)
      Semian.notify(:state_change, self, nil, nil, state: new_state)
    end

    def maybe_with_half_open_resource_timeout(resource, &block)
      if half_open? && @half_open_resource_timeout && resource.respond_to?(:with_resource_timeout)
        resource.with_resource_timeout(@half_open_resource_timeout) do
          block.call
        end
      else
        block.call
      end
    end
  end
end
