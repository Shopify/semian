# frozen_string_literal: true

require_relative "circuit_breaker"

module Semian
  class ErrorRateCircuitBreaker < CircuitBreaker # :nodoc:
    NON_REQUEST_SCOPES = [:connection, :ping].freeze
    # Fiber-local: the innermost running acquire, as [breaker, failure counted?, enclosing acquire, success deferred?].
    ACQUISITION = :semian_error_rate_acquisition
    TRIP_RATE = :semian_error_rate_trip_rate

    attr_reader :error_rate_threshold, :minimum_request_volume

    def initialize(name, error_rate_threshold:, implementation:, minimum_request_volume: 10, error_rate_window: 10,
      **options)
      @error_rate_threshold = error_rate_threshold
      @minimum_request_volume = minimum_request_volume
      @outcomes = implementation::TimeBucketedCounter.new(window: error_rate_window)
      # Error that ended an acquire => did that acquire (the last one it ended) count a failure? Keyed by identity,
      # so errors are neither modified nor retained. The values are immediates, which a WeakMap never drops.
      @ended_acquisitions = ObjectSpace::WeakMap.new
      @reports = Mutex.new

      # error_threshold only sizes the parent's last-error window, which we use for error_timeout.
      super(name, error_threshold: 1, implementation: implementation, **options)
    end

    def acquire(resource = nil, scope: nil, adapter: nil, &block)
      previous = Thread.current[ACQUISITION]
      frame = Thread.current[ACQUISITION] = [self, false, previous]
      transition_to_half_open(scope: scope, adapter: adapter) if transition_to_half_open?
      raise OpenCircuitError unless request_allowed?

      begin
        result = maybe_with_half_open_resource_timeout(resource, &block)
      rescue Exception => error # rubocop:disable Lint/RescueException -- adapters can report any raised exception after acquire unwinds
        marks = @exceptions.any? { |exception| exception === error } && # rubocop:disable Style/CaseEquality -- as rescue matches
          (!error.respond_to?(:marks_semian_circuits?) || error.marks_semian_circuits?)
        @reports.synchronize do
          @ended_acquisitions[error] = frame[1]
          # Claimed below through the error; reports of other errors while that one is notified find it taken.
          frame[1] = true if marks
        end
        mark_failed(error, scope: scope, adapter: adapter) if marks
        raise
      else
        mark_success(scope: scope, adapter: adapter)
      end
      result
    ensure
      Thread.current[ACQUISITION] = previous
    end

    # A failure reported with the error that ended an acquire of this breaker belongs to that acquire, whenever and
    # wherever it is reported. Any other report belongs to the innermost running acquire of this breaker in this
    # fiber, if there is one. Each acquire counts at most one failure.
    def mark_failed(error, scope: nil, adapter: nil)
      return if already_counted?(error)

      # A report made while another transition of this fiber is being notified must not disturb that one's rate.
      previous_rate = Thread.current[TRIP_RATE]
      begin
        Thread.current[TRIP_RATE] = nil
        @outcomes.record_failure
        super
      ensure
        Thread.current[TRIP_RATE] = previous_rate
      end
    end

    def mark_success(scope: nil, adapter: nil)
      frame = Thread.current[ACQUISITION]
      neutral = (frame && frame[0].equal?(self) && (frame[1] || frame[3])) || NON_REQUEST_SCOPES.include?(scope)
      @outcomes.record_success unless neutral
      super
    end

    class << self
      # Identifies the innermost acquire that is running in this fiber, of any rate-based breaker.
      def acquisition
        Thread.current[ACQUISITION]
      end

      # An acquire that started after `since` was taken and is still running only admitted work whose outcome a later
      # acquire records, so its success is neutral in the rate; a failure still counts. It remains a half-open
      # success, as a successful connection is. Comparing acquires rather than asking the caller whether it acquired
      # leaves nothing to go stale: no new acquire means nothing is deferred.
      def defer_outcome(since:)
        frame = Thread.current[ACQUISITION]
        frame[3] = true if frame && !frame.equal?(since)
      end
    end

    def destroy
      @outcomes.destroy
      super
    end

    def error_rate
      successes, failures = @outcomes.counts
      total = successes + failures
      total.zero? ? 0.0 : failures.fdiv(total)
    end

    private

    # Atomically claims the failure of the acquire that the report belongs to; concurrent reports cannot both win.
    def already_counted?(error)
      @reports.synchronize do
        if @ended_acquisitions.key?(error)
          return true if @ended_acquisitions[error]

          @ended_acquisitions[error] = true
        elsif (frame = running_acquisition)
          return true if frame[1]

          frame[1] = true
        end
        false
      end
    end

    def running_acquisition
      frame = Thread.current[ACQUISITION]
      frame = frame[2] while frame && !frame[0].equal?(self)
      frame
    end

    def error_threshold_reached?
      successes, failures = @outcomes.counts
      total = successes + failures
      return false if total < @minimum_request_volume

      rate = failures.fdiv(total)
      return false if rate < @error_rate_threshold

      Thread.current[TRIP_RATE] = [self, rate]
      true
    end

    # Outcomes recorded before the circuit closes are forgotten and those recorded after are kept, even when they
    # are recorded while it closes.
    def close_state
      @outcomes.clear { super }
    end

    # A close that finished while this failure was being notified forgot when the last error happened; without it the
    # circuit would stay open forever.
    def open_state
      @outcomes.synchronize do
        @errors << Process.clock_gettime(Process::CLOCK_MONOTONIC) if @errors.empty?
        super
      end
    end

    def transition_error_rate
      trip = Thread.current[TRIP_RATE]
      trip && trip[0].equal?(self) ? trip[1] : error_rate
    end

    def notify_state_transition(new_state, scope: nil, adapter: nil)
      Semian.notify(:state_change, self, scope, adapter, state: new_state, error_rate: transition_error_rate)
    end

    def observed_errors_log
      " error_rate=#{transition_error_rate.round(4)}"
    end

    def error_threshold_log
      " error_rate_threshold=#{@error_rate_threshold} minimum_request_volume=#{@minimum_request_volume}"
    end
  end
end
