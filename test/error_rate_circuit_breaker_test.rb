# frozen_string_literal: true

require "test_helper"

class TestErrorRateCircuitBreaker < Minitest::Test
  include CircuitBreakerHelper
  include TimeHelper

  OtherError = Class.new(StandardError)

  class IgnoredError < StandardError
    def marks_semian_circuits?
      false
    end
  end

  def setup
    @strio = StringIO.new
    Semian.logger = Logger.new(@strio)
    destroy_all_semian_resources
    @resource = register(:testing)
    @breaker = @resource.circuit_breaker
  end

  def teardown
    Semian.unsubscribe(:error_rate_test)
  end

  def test_register_builds_an_error_rate_circuit_breaker
    assert_instance_of(Semian::ErrorRateCircuitBreaker, @breaker)
    assert_equal(0.5, @breaker.error_rate_threshold)
    assert_equal(4, @breaker.minimum_request_volume)
  end

  def test_opens_when_the_error_rate_reaches_the_threshold
    2.times { succeed! }
    trigger_error!

    refute_predicate(@breaker, :open?)

    trigger_error!

    assert_circuit_opened
    assert_in_delta(0.5, @breaker.error_rate)
  end

  def test_exact_decimal_threshold_is_not_missed_due_to_multiplication_rounding
    resource = register(:decimal, error_rate_threshold: 0.07, minimum_request_volume: 100)
    93.times { succeed!(resource) }
    7.times { trigger_error!(resource) }

    assert_predicate(resource, :open?)
    assert_in_delta(0.07, resource.circuit_breaker.error_rate)
  end

  def test_does_not_open_on_many_errors_when_the_error_rate_stays_below_the_threshold
    20.times { succeed! }
    6.times { trigger_error! }

    assert_in_delta(6 / 26.0, @breaker.error_rate)
    assert_circuit_closed
  end

  def test_does_not_open_below_the_minimum_request_volume
    3.times { trigger_error! }

    refute_predicate(@breaker, :open?)

    trigger_error!

    assert_circuit_opened
  end

  def test_successes_are_counted_while_the_circuit_is_closed
    4.times { succeed! }

    assert_in_delta(0.0, @breaker.error_rate)

    trigger_error!

    assert_in_delta(0.2, @breaker.error_rate)
  end

  def test_outcomes_outside_the_window_are_forgotten
    3.times { trigger_error! }
    time_travel(11) do
      trigger_error!

      refute_predicate(@breaker, :open?)
      assert_in_delta(1.0, @breaker.error_rate)
    end
  end

  def test_non_resource_errors_and_errors_that_do_not_mark_circuits_are_neutral
    resource = register(:ignored, exceptions: [SomeError, IgnoredError])
    succeed!(resource)
    trigger_error!(resource)

    3.times do
      assert_raises(OtherError) { resource.acquire { raise OtherError } }
      assert_raises(IgnoredError) { resource.acquire { raise IgnoredError } }
    end

    assert_equal([1, 1], counts(resource))
  end

  def test_open_circuit_rejections_are_not_counted
    2.times { succeed! }
    open_circuit!(@resource, 2)

    10.times { assert_raises(Semian::OpenCircuitError) { @resource.acquire {} } }

    assert_equal([2, 2], counts(@resource))
  end

  def test_successful_connections_and_pings_do_not_dilute_the_error_rate
    5.times do
      @resource.acquire(scope: :connection) {}
      @resource.acquire(scope: :ping) {}
    end

    assert_in_delta(0.0, @breaker.error_rate)

    trigger_error!

    assert_in_delta(1.0, @breaker.error_rate)
  end

  def test_failed_connections_are_counted
    assert_raises(SomeError) { @resource.acquire(scope: :connection) { raise SomeError } }

    assert_in_delta(1.0, @breaker.error_rate)
  end

  def test_a_failure_marked_inside_the_block_is_not_also_counted_as_a_success
    resource = register(:marked_in_block, error_rate_threshold: 0.75)
    3.times { resource.acquire { resource.mark_failed(SomeError.new) } }

    assert_in_delta(1.0, resource.circuit_breaker.error_rate)

    resource.acquire { resource.mark_failed(SomeError.new) }

    assert_circuit_opened(resource)
  end

  def test_a_failure_marked_in_one_thread_does_not_hide_a_success_in_another
    inside_block = Queue.new
    release = Queue.new
    thread = Thread.new do
      @resource.acquire do
        @resource.mark_failed(SomeError.new)
        inside_block << true
        release.pop
      end
    end
    inside_block.pop
    succeed!
    release << true
    thread.join

    assert_in_delta(0.5, @breaker.error_rate)
  end

  def test_half_open_circuit_closes_after_success_threshold_and_forgets_outcomes
    half_open_cicuit!(@resource, 10, 4)

    assert_circuit_closed
    assert_match(/State transition from open to half_open/, @strio.string)
    assert_in_delta(0.0, @breaker.error_rate)

    3.times { trigger_error! }

    refute_predicate(@breaker, :open?)
  end

  def test_a_half_open_failure_recorded_while_the_circuit_closes_is_forgotten
    resource = register(:closing, minimum_request_volume: 2)
    half_open_cicuit!(resource, 10, 2)
    closing = Queue.new
    failed = Queue.new
    Semian.subscribe(:error_rate_test) do |event, _resource, _scope, _adapter, payload|
      next unless event == :state_change && payload[:state] == :closed

      closing << true
      failed.pop(timeout: 5)
    end
    closer = Thread.new { succeed!(resource) }

    assert(closing.pop(timeout: 5), "Expected the circuit to start closing")
    trigger_error!(resource)
    failed << true

    assert(closer.join(5), "Expected the circuit to finish closing")
    assert_predicate(resource, :closed?)
    assert_equal([0, 0], counts(resource))

    trigger_error!(resource)

    assert_predicate(resource, :closed?)
    assert_equal([0, 1], counts(resource))
  end

  def test_outcomes_recorded_once_the_circuit_closed_are_kept_while_the_transition_finishes
    resource = register(:closed_early, minimum_request_volume: 4)
    half_open_cicuit!(resource, 10, 4)
    closed, resume = pause_closer_once_closed(resource)
    closer = Thread.new do
      Thread.current[:semian_test_closer] = true
      succeed!(resource)
    end

    assert(closed.pop(timeout: 5), "Expected the circuit to close")
    assert_predicate(resource, :closed?)
    succeed!(resource)
    trigger_error!(resource)
    resume << true

    assert(closer.join(5), "Expected the transition to finish")
    assert_equal([1, 1], counts(resource))
  end

  def test_a_failure_that_opens_the_circuit_while_the_close_finishes_does_not_leave_it_open_forever
    resource = register(:reopened, minimum_request_volume: 1, success_threshold: 2)
    half_open_cicuit!(resource, 10, 1)
    succeed!(resource)
    closed, resume = pause_closer_once_closed(resource)
    closer = Thread.new do
      Thread.current[:semian_test_closer] = true
      succeed!(resource)
    end

    assert(closed.pop(timeout: 5), "Expected the circuit to close")
    trigger_error!(resource)

    assert_predicate(resource, :open?)

    resume << true

    assert(closer.join(5), "Expected the transition to finish")
    assert_predicate(resource, :open?)
    assert_equal([0, 1], counts(resource))
    time_travel(6) do
      succeed!(resource)

      assert_predicate(resource, :half_open?)
    end
  end

  def test_a_subscriber_reporting_a_failure_while_the_circuit_closes_does_not_deadlock
    half_open_cicuit!(@resource, 10, 4)
    Semian.subscribe(:error_rate_test) do |event, resource, _scope, _adapter, payload|
      resource.mark_failed(SomeError.new) if event == :state_change && payload[:state] == :closed
    end

    assert(Thread.new { succeed! }.join(5), "Expected the circuit to finish closing")
    assert_predicate(@resource, :closed?)
    assert_equal([0, 0], counts(@resource))
  end

  def test_a_half_open_failure_that_opens_the_circuit_after_another_probe_closed_it_does_not_leave_it_open_forever
    resource = register(:reopened_late, minimum_request_volume: 1, success_threshold: 2)
    half_open_cicuit!(resource, 10, 1)
    succeed!(resource)
    opening = Queue.new
    resume = Queue.new
    Semian.subscribe(:error_rate_test) do |event, _resource, _scope, _adapter, payload|
      next unless event == :state_change && payload[:state] == :open

      opening << true
      resume.pop(timeout: 5)
    end
    failer = Thread.new { trigger_error!(resource) }

    assert(opening.pop(timeout: 5), "Expected the failing probe to start opening the circuit")
    assert_predicate(resource, :half_open?)

    succeed!(resource)

    assert_predicate(resource, :closed?)
    assert_nil(last_error_time(resource))

    succeed!(resource)
    resume << true

    assert(failer.join(5), "Expected the failing probe to finish")
    assert_predicate(resource, :open?)
    assert_equal([1, 0], counts(resource))
    refute_nil(last_error_time(resource), "Expected the open circuit to remember when the last error happened")
    time_travel(4) { assert_circuit_opened(resource) }
    time_travel(6) do
      succeed!(resource)

      assert_predicate(resource, :half_open?)
    end
  end

  def test_a_subscriber_resetting_the_circuit_while_it_opens_does_not_deadlock_or_leave_it_open_forever
    Semian.subscribe(:error_rate_test) do |event, resource, _scope, _adapter, payload|
      resource.reset if event == :state_change && payload[:state] == :open
    end

    assert(Thread.new { open_circuit!(@resource, 4) }.join(5), "Expected the circuit to finish opening")
    assert_predicate(@resource, :open?)
    refute_nil(last_error_time(@resource))
    time_travel(6) { assert_circuit_closed }
  end

  def test_error_in_half_open_state_reopens_the_circuit
    half_open_cicuit!(@resource, 10, 4)
    time_travel(1) { trigger_error! }

    assert_circuit_opened
  end

  def test_reset_closes_the_circuit_and_forgets_outcomes
    open_circuit!(@resource, 4)
    @resource.reset

    assert_circuit_closed
    assert_in_delta(0.0, @breaker.error_rate)
  end

  def test_exponential_backoff_still_applies
    resource = register(:backoff, exponential_backoff_error_timeout: true, error_timeout: 16, success_threshold: 2)
    open_circuit!(resource, 4)

    time_travel(0.5) { assert_circuit_opened(resource) }
    time_travel(1.5) do
      resource.acquire { nil }

      assert_predicate(resource, :half_open?)
    end
  end

  def test_half_open_resource_timeout_is_passed_to_the_resource
    resource = register(:timed, half_open_resource_timeout: 0.25, success_threshold: 2)
    client = Object.new
    client.expects(:with_resource_timeout).with(0.25).yields
    open_circuit!(resource, 4)

    time_travel(6) { resource.acquire(resource: client) {} }

    assert_predicate(resource, :half_open?)
  end

  def test_backoff_increases_after_a_half_open_failure_and_resets_after_recovery
    resource = register(:backoff_cycle, exponential_backoff_error_timeout: true, error_timeout: 16, success_threshold: 2)
    open_circuit!(resource, 4)
    time_travel(1.5) { trigger_error!(resource) }

    time_travel(3) { assert_circuit_opened(resource) }
    time_travel(3.6) do
      2.times { succeed!(resource) }

      assert_predicate(resource, :closed?)

      open_circuit!(resource, 4)
    end

    time_travel(4.1) { assert_circuit_opened(resource) }
    time_travel(4.8) do
      succeed!(resource)

      assert_predicate(resource, :half_open?)
    end
  end

  def test_state_change_notification_carries_the_error_rate
    payloads = []
    Semian.subscribe(:error_rate_test) { |event, _resource, _scope, _adapter, payload| payloads << payload if event == :state_change }
    open_circuit!(@resource, 4)

    assert_equal({ state: :open, error_rate: 1.0 }, payloads.last)
  end

  def test_transition_log_carries_the_error_rate_instead_of_error_counts
    open_circuit!(@resource, 4)

    assert_match(/State transition from closed to open\. success_count=0 error_rate=1\.0 success_count_threshold=1 error_rate_threshold=0\.5 minimum_request_volume=4/, @strio.string)
    refute_match(/error_count/, @strio.string)
  end

  def test_works_without_thread_safety
    resource = register(:simple, thread_safety_disabled: true)
    open_circuit!(resource, 4)

    assert_circuit_opened(resource)
  end

  def test_defaults_when_only_the_error_rate_threshold_is_given
    resource = Semian.register(:defaults, bulkhead: false, success_threshold: 1, error_timeout: 5, error_rate_threshold: 0.5)

    assert_equal(10, resource.circuit_breaker.minimum_request_volume)
  end

  def test_error_rate_threshold_replaces_the_error_threshold_options
    resource = register(:replaces, minimum_request_volume: 10)
    9.times { trigger_error!(resource) }

    refute_predicate(resource, :open?)

    trigger_error!(resource)

    assert_circuit_opened(resource)
  end

  def test_classic_circuit_breaker_is_used_without_an_error_rate_threshold
    resource = Semian.register(:classic, bulkhead: false, success_threshold: 1, error_threshold: 2, error_timeout: 5)

    assert_instance_of(Semian::CircuitBreaker, resource.circuit_breaker)
  end

  def test_invalid_error_rate_options_raise_whether_or_not_validation_is_forced
    {
      error_rate_threshold: [false, 0, 1, -0.1, 1.5, 50, "0.5", Float::NAN, Complex(0.5, 1)],
      minimum_request_volume: [0, -1, 1.5, "3"],
      error_rate_window: [0, -1, "3", Float::INFINITY, Float::NAN, Complex(1, 1)],
    }.each do |option, values|
      values.product([true, false, nil]).each do |value, force|
        error = assert_raises(ArgumentError) { register(:invalid, option => value, force_config_validation: force) }
        assert_match("Semian Resource invalid: #{option} must be a", error.message)
        assert_nil(Semian[:invalid])
      end
    end

    refute_match(/SEMIAN_CONFIG_WARNING/, @strio.string)
  end

  def test_validation_still_requires_success_threshold_and_error_timeout
    error = assert_raises(ArgumentError) do
      Semian.register(:invalid, force_config_validation: true, bulkhead: false, error_rate_threshold: 0.5)
    end
    assert_match("Missing required arguments for Semian: [:success_threshold, :error_timeout]", error.message)
  end

  def test_validation_rejects_options_that_are_ignored
    error = assert_raises(ArgumentError) { register(:invalid, error_threshold: 3, lumping_interval: 1) }
    assert_match("error_threshold, lumping_interval ignored when error_rate_threshold is set", error.message)
  end

  def test_validation_accepts_nil_for_options_that_are_ignored
    register(:nils, error_threshold: nil, error_threshold_timeout: nil, error_threshold_timeout_enabled: nil, lumping_interval: nil)

    refute_match(/ignored when error_rate_threshold is set/, @strio.string)
  end

  def test_registration_rejects_adaptive_and_dual_circuit_breakers_whether_or_not_validation_is_forced
    [:adaptive_circuit_breaker, :dual_circuit_breaker].product([true, false, nil]).each do |option, force|
      error = assert_raises(ArgumentError) { register(:invalid, option => true, force_config_validation: force) }
      assert_match("error_rate_threshold is not supported with adaptive_circuit_breaker or dual_circuit_breaker", error.message)
      assert_nil(Semian[:invalid])
    end
  end

  def test_adaptive_and_dual_are_not_rejected_when_the_circuit_breaker_is_disabled
    [:adaptive_circuit_breaker, :dual_circuit_breaker].each do |option|
      options = { error_rate_threshold: 0.5, circuit_breaker: false, tickets: 1, force_config_validation: true, option => true }

      assert_nil(Semian::ConfigurationValidator.new(option, options).validate!)
    end

    ENV["SEMIAN_CIRCUIT_BREAKER_DISABLED"] = "1"

    [:adaptive_circuit_breaker, :dual_circuit_breaker].each do |option|
      assert_nil(register(option, option => true, force_config_validation: false).circuit_breaker)
    end
  ensure
    ENV.delete("SEMIAN_CIRCUIT_BREAKER_DISABLED")
  end

  def test_multiple_failure_reports_in_one_acquire_count_once
    2.times { succeed! }
    assert_raises(SomeError) do
      @resource.acquire do
        @resource.mark_failed(SomeError.new)
        @resource.mark_failed(SomeError.new)
        raise SomeError
      end
    end

    assert_equal([2, 1], counts(@resource))
    refute_predicate(@resource, :open?)
  end

  def test_post_acquire_adapter_report_does_not_count_an_already_recorded_error_twice
    2.times { succeed! }
    error = SomeError.new
    begin
      @resource.acquire { raise error }
    rescue SomeError => caught
      @resource.mark_failed(caught)
    end

    assert_equal([2, 1], counts(@resource))
    refute_predicate(@resource, :open?)
  end

  def test_a_subsequent_acquire_can_count_the_same_exception_again
    error = SomeError.new

    2.times { assert_raises(SomeError) { @resource.acquire { raise error } } }

    assert_equal([0, 2], counts(@resource))
  end

  def test_nested_failures_and_post_acquire_reports_only_affect_their_resource
    inner = register(:inner)
    @resource.acquire do
      inner.acquire { raise OtherError }
    rescue OtherError => error
      inner.mark_failed(error)
    end

    assert_equal([1, 0], counts(@resource))
    assert_equal([0, 1], counts(inner))
  end

  def test_nested_same_resource_adapter_report_is_not_assigned_to_the_outer_acquire
    2.times { succeed! }
    @resource.acquire do
      @resource.acquire { raise SomeError }
    rescue SomeError => error
      @resource.mark_failed(error)
    end

    assert_equal([3, 1], counts(@resource))
    refute_predicate(@resource, :open?)
  end

  def test_nested_same_resource_propagated_error_counts_for_each_acquire
    2.times { succeed! }
    assert_raises(SomeError) { @resource.acquire { @resource.acquire { raise SomeError } } }

    assert_equal([2, 2], counts(@resource))
    assert_predicate(@resource, :open?)
  end

  def test_nested_same_resource_report_of_an_unlisted_error_does_not_hide_the_outer_success
    resource = register(:nested_unlisted, error_rate_threshold: 0.75)
    4.times do
      resource.acquire do
        resource.acquire { raise OtherError }
      rescue OtherError => error
        resource.mark_failed(error)
      end
    end

    assert_equal([4, 4], counts(resource))
    refute_predicate(resource, :open?)
  end

  def test_nested_same_resource_report_is_counted_when_the_outer_acquire_already_failed
    @resource.acquire do
      @resource.mark_failed(SomeError.new)
      @resource.acquire { raise OtherError }
    rescue OtherError => error
      @resource.mark_failed(error)
    end

    assert_equal([0, 2], counts(@resource))
  end

  def test_nested_same_resource_reports_after_each_acquire_count_once_per_acquire
    begin
      @resource.acquire do
        @resource.acquire { raise OtherError }
      rescue OtherError => error
        @resource.mark_failed(error)
        raise
      end
    rescue OtherError => error
      @resource.mark_failed(error)
    end

    assert_equal([0, 2], counts(@resource))

    @resource.mark_failed(error)

    assert_equal([0, 2], counts(@resource))
  end

  def test_report_after_an_error_unwound_several_resources_is_counted_once_per_resource
    inner = register(:inner)
    begin
      @resource.acquire { inner.acquire { raise SomeError } }
    rescue SomeError => error
      inner.mark_failed(error)
      @resource.mark_failed(error)
    end

    assert_equal([0, 1], counts(inner))
    assert_equal([0, 1], counts(@resource))
  end

  def test_deferred_report_is_not_counted_again_after_intervening_acquires
    other = register(:other)
    error = SomeError.new
    begin
      @resource.acquire { raise error }
    rescue SomeError
      assert_raises(SomeError) { other.acquire { raise SomeError } }
      other.acquire {}
      @resource.mark_failed(error)
    end
    succeed!
    assert_raises(SomeError) { @resource.acquire { raise SomeError } }
    assert_raises(OtherError) { @resource.acquire { raise OtherError } }
    @resource.mark_failed(error)

    assert_equal([1, 2], counts(@resource))
    assert_equal([1, 1], counts(other))
  end

  def test_deferred_report_of_an_unlisted_error_is_counted_once_after_intervening_acquires
    error = OtherError.new
    assert_raises(OtherError) { @resource.acquire { raise error } }
    succeed!
    assert_raises(SomeError) { @resource.acquire { raise SomeError } }

    assert_equal([1, 1], counts(@resource))

    2.times { @resource.mark_failed(error) }

    assert_equal([1, 2], counts(@resource))
  end

  def test_deferred_report_inside_a_later_acquire_does_not_hide_its_success
    listed = SomeError.new
    unlisted = OtherError.new
    assert_raises(SomeError) { @resource.acquire { raise listed } }
    assert_raises(OtherError) { @resource.acquire { raise unlisted } }
    @resource.acquire do
      @resource.mark_failed(listed)
      @resource.mark_failed(unlisted)
    end

    assert_equal([1, 2], counts(@resource))
  end

  def test_deferred_reports_are_tracked_per_error_and_per_resource
    inner = register(:inner)
    errors = Array.new(3) { SomeError.new }

    errors.each do |error|
      assert_raises(SomeError) { @resource.acquire { inner.acquire { raise error } } }
    end
    errors.reverse_each do |error|
      inner.mark_failed(error)
      @resource.mark_failed(error)
    end

    assert_equal([0, 3], counts(@resource))
    assert_equal([0, 3], counts(inner))
  end

  def test_standalone_reports_are_each_counted
    error = SomeError.new
    2.times { @resource.mark_failed(error) }
    @resource.mark_failed(SomeError.new)

    assert_equal([0, 3], counts(@resource))
  end

  def test_an_ended_acquire_counts_once_whichever_fiber_or_thread_reports_it
    error = OtherError.new
    fiber = Fiber.new do
      assert_raises(OtherError) { @resource.acquire { raise error } }
      Fiber.yield
      @resource.mark_failed(error)
    end
    fiber.resume
    Thread.new { @resource.mark_failed(error) }.join
    fiber.resume
    @resource.mark_failed(error)

    assert_equal([0, 1], counts(@resource))
  end

  def test_an_already_counted_frozen_error_is_not_counted_again_even_after_other_acquires
    error = SomeError.new.freeze
    assert_raises(SomeError) { @resource.acquire { raise error } }
    succeed!
    trigger_error!
    2.times { @resource.mark_failed(error) }

    assert_equal([1, 2], counts(@resource))
  end

  def test_simultaneous_reports_of_an_unlisted_error_count_exactly_once
    resource = register(:busy, minimum_request_volume: 100)
    20.times do |round|
      error = OtherError.new
      assert_raises(OtherError) { resource.acquire { raise error } }
      report_simultaneously(8) { resource.mark_failed(error) }

      assert_equal([0, round + 1], counts(resource))
    end
  end

  def test_simultaneous_reports_of_a_frozen_unlisted_error_from_threads_and_fibers_count_exactly_once
    error = OtherError.new.freeze
    assert_raises(OtherError) { @resource.acquire { raise error } }
    report_simultaneously(8) { Fiber.new { @resource.mark_failed(error) }.resume }
    @resource.mark_failed(error)

    assert_equal([0, 1], counts(@resource))
  end

  def test_tracking_survives_gc_while_the_error_is_alive_and_does_not_retain_it
    uncounted = OtherError.new.freeze
    counted = SomeError.new

    [uncounted, counted].each { |error| assert_raises(error.class) { @resource.acquire { raise error } } }
    ids = track_and_drop_unlisted_errors(200)
    tracked = @breaker.instance_variable_get(:@ended_acquisitions)

    retained = ids.size
    10.times do
      GC.start
      retained = ids.count { |id| tracked.keys.any? { |key| key.__id__ == id } }
      break if retained.zero?
    end

    assert_operator(retained, :<, ids.size / 10, "the breaker retains errors that ended its acquires")
    refute(tracked[uncounted])
    assert(tracked[counted])

    2.times { [uncounted, counted].each { |error| @resource.mark_failed(error) } }

    assert_equal([0, 2], counts(@resource))
  end

  def test_tracking_leaves_errors_and_fiber_local_state_untouched_and_marshaled_copies_independent
    error = SomeError.new("boom")
    assert_raises(SomeError) { @resource.acquire { register(:inner).acquire { raise error } } }
    @resource.mark_failed(error)

    assert_empty(error.instance_variables)
    refute_predicate(error, :frozen?)
    assert_nil(Thread.current[Semian::ErrorRateCircuitBreaker::ACQUISITION])
    assert_nil(Thread.current[Semian::ErrorRateCircuitBreaker::TRIP_RATE])

    copy = Marshal.load(Marshal.dump(error))
    2.times { @resource.mark_failed(copy) }
    @resource.mark_failed(error)

    assert_equal("boom", copy.message)
    assert_empty(copy.instance_variables)
    assert_equal([0, 3], counts(@resource))
  end

  def test_a_duplicate_report_during_a_transition_keeps_the_rate_of_that_transition
    error = SomeError.new
    assert_raises(SomeError) { @resource.acquire { raise error } }
    rates = []
    Semian.subscribe(:error_rate_test) do |event, resource, *|
      next unless event == :state_change

      resource.mark_failed(error)
      rates << Thread.current[Semian::ErrorRateCircuitBreaker::TRIP_RATE]&.last
    end
    3.times { trigger_error! }

    assert_equal([1.0], rates)
    assert_equal([0, 4], counts(@resource))
  end

  def test_a_report_of_another_error_during_the_transition_tripped_by_an_acquire_is_not_counted_again
    resource = register(:trips_at_once, minimum_request_volume: 1)
    reports = 0
    Semian.subscribe(:error_rate_test) do |event, notifier, *|
      next unless event == :state_change && (reports += 1) == 1

      notifier.mark_failed(SomeError.new)
    end

    assert_raises(SomeError) { resource.acquire { raise SomeError } }

    assert_equal(1, reports)
    assert_equal([0, 1], counts(resource))
    assert_predicate(resource, :open?)
  end

  def test_deferred_report_after_recovery_or_reset_is_not_counted
    error = SomeError.new
    3.times { trigger_error! }
    assert_raises(SomeError) { @resource.acquire { raise error } }

    assert_predicate(@resource, :open?)

    @resource.reset
    @resource.mark_failed(error)

    assert_equal([0, 0], counts(@resource))
    assert_predicate(@resource, :closed?)
  end

  def test_deferred_report_does_not_refresh_the_last_error_or_reopen_a_half_open_circuit
    resource = register(:recovering, success_threshold: 2)
    error = SomeError.new("first")
    3.times { trigger_error!(resource) }
    assert_raises(SomeError) { resource.acquire { raise error } }

    time_travel(4) do
      resource.mark_failed(error)
    end
    time_travel(6) do
      succeed!(resource)
      resource.mark_failed(error)

      assert_predicate(resource, :half_open?)
    end
  end

  def test_destroy_clears_the_outcomes
    2.times { trigger_error! }
    Semian.destroy(:testing)

    assert_equal([0, 0], @breaker.instance_variable_get(:@outcomes).counts)
  end

  def test_nested_acquires_restore_the_outer_failure_marker
    inner = register(:inner)
    @resource.acquire do
      @resource.mark_failed(SomeError.new)
      inner.acquire {}
    end

    assert_equal([0, 1], counts(@resource))
    assert_equal([1, 0], counts(inner))
  end

  def test_failure_marker_is_fiber_local
    fiber = Fiber.new do
      @resource.acquire do
        @resource.mark_failed(SomeError.new)
        Fiber.yield
      end
    end
    fiber.resume
    succeed!
    fiber.resume

    assert_equal([1, 1], counts(@resource))
  end

  def test_half_open_requires_multiple_successes_before_clearing
    resource = register(:recovery, success_threshold: 2)
    open_circuit!(resource, 4)
    time_travel(6) do
      succeed!(resource)

      assert_predicate(resource, :half_open?)

      succeed!(resource)

      assert_predicate(resource, :closed?)
      assert_equal([0, 0], counts(resource))
    end
  end

  def test_open_notification_and_log_use_the_trip_snapshot
    2.times { succeed! }
    trigger_error!
    ready = Queue.new
    resume_transition = Queue.new
    @breaker.singleton_class.prepend(Module.new do
      define_method(:transition_to_open) do |**options|
        ready << true
        resume_transition.pop
        super(**options)
      end
    end)
    payloads = []
    Semian.subscribe(:error_rate_test) { |event, _, _, _, payload| payloads << payload if event == :state_change }
    thread = Thread.new { trigger_error! }
    ready.pop
    succeed!
    resume_transition << true
    thread.value

    assert_equal({ state: :open, error_rate: 0.5 }, payloads.last)
    assert_match(/error_rate=0\.5 /, @strio.string)
    assert_in_delta(0.4, @breaker.error_rate)
  ensure
    resume_transition << true if thread&.alive?
    thread&.join
  end

  def test_warns_once_for_ignored_legacy_options_without_validating_them
    resource = register(
      :ignored_options,
      force_config_validation: false,
      error_threshold: "old",
      error_threshold_timeout: 0,
      error_threshold_timeout_enabled: false,
      lumping_interval: 0,
    )

    assert_instance_of(Semian::ErrorRateCircuitBreaker, resource.circuit_breaker)
    assert_match(/error_threshold, error_threshold_timeout, error_threshold_timeout_enabled, lumping_interval ignored/, @strio.string)
    assert_equal(1, @strio.string.scan("SEMIAN_CONFIG_WARNING").size)
  end

  def test_rate_mode_preserves_shared_configuration_validation
    [
      [{ success_threshold: 0 }, /success_threshold must be a positive integer/],
      [{ error_timeout: 0 }, /error_timeout must be a positive number/],
      [{ half_open_resource_timeout: 0 }, /half_open_resource_timeout must be a positive number/],
      [{ exponential_backoff_error_timeout: "yes" }, /exponential_backoff_error_timeout must be a boolean/],
      [{ exponential_backoff_initial_timeout: 2 }, /initial_timeout can only be specified/],
      [{ exponential_backoff_error_timeout: true, exponential_backoff_multiplier: 1 }, /multiplier must be a number greater than 1/],
    ].each do |options, message|
      error = assert_raises(ArgumentError) { register(:invalid, **options) }
      assert_match(message, error.message)
    end
  end

  def test_disabled_breaker_is_not_created
    resource = register(:disabled, force_config_validation: false, circuit_breaker: false)

    assert_nil(resource.circuit_breaker)
  end

  private

  def report_simultaneously(threads)
    ready = Queue.new
    start = Queue.new
    reporters = Array.new(threads) do
      Thread.new do
        ready << true
        start.pop
        yield
      end
    end
    threads.times { ready.pop }
    threads.times { start << true }
    reporters.each(&:join)
  end

  # In a method of its own, so that no local keeps the errors alive.
  def track_and_drop_unlisted_errors(count)
    Array.new(count) do
      error = OtherError.new
      assert_raises(OtherError) { @resource.acquire { raise error } }
      error.__id__
    end
  end

  # Pauses the thread flagged :semian_test_closer once it closed the circuit and released the outcomes.
  def pause_closer_once_closed(resource)
    closed = Queue.new
    resume = Queue.new
    resource.circuit_breaker.instance_variable_get(:@outcomes).singleton_class.prepend(Module.new do
      define_method(:clear) do |&block|
        result = super(&block)
        if Thread.current[:semian_test_closer]
          closed << true
          resume.pop(timeout: 5)
        end
        result
      end
    end)
    [closed, resume]
  end

  def last_error_time(resource)
    resource.circuit_breaker.instance_variable_get(:@errors).last
  end

  def counts(resource)
    resource.circuit_breaker.instance_variable_get(:@outcomes).counts
  end

  def register(name, **options)
    Semian.register(
      name,
      bulkhead: false,
      exceptions: [SomeError],
      error_rate_threshold: 0.5,
      minimum_request_volume: 4,
      error_rate_window: 10,
      error_timeout: 5,
      success_threshold: 1,
      force_config_validation: true,
      **options,
    )
  end

  def succeed!(resource = @resource)
    resource.acquire {}
  end

  def open_circuit!(resource = @resource, error_count = 4)
    super
  end

  def half_open_cicuit!(resource = @resource, backwards_time_travel = 10, error_count = 4)
    time_travel(-backwards_time_travel) { open_circuit!(resource, error_count) }
  end
end
