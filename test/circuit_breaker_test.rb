# frozen_string_literal: true

require "test_helper"

class TestCircuitBreaker < Minitest::Test
  include CircuitBreakerHelper
  include TimeHelper

  def setup
    @strio = StringIO.new
    Semian.logger = Logger.new(@strio)
    destroy_all_semian_resources
    # Ensure validation errors are raised for all tests to maintain existing behavior
    Semian.register(
      :testing,
      tickets: 1,
      exceptions: [SomeError],
      error_threshold: 2,
      error_timeout: 5,
      success_threshold: 1,
      error_threshold_timeout: 5,
      force_config_validation: true,
    )
    @resource = Semian[:testing]
  end

  def test_acquire_yield_when_the_circuit_is_closed
    block_called = false
    @resource.acquire { block_called = true }

    assert(block_called)
  end

  def test_acquire_raises_circuit_open_error_when_the_circuit_is_open
    open_circuit!
    assert_raises(Semian::OpenCircuitError) do
      @resource.acquire { 1 + 1 }
    end

    assert_match(/State transition from closed to open/, @strio.string)
  end

  def test_last_error_message_is_logged_when_circuit_opens
    open_circuit!

    assert_match(/last_error_message="some error message"/, @strio.string)
  end

  def test_after_error_threshold_the_circuit_is_open
    open_circuit!

    assert_circuit_opened
  end

  def test_after_error_timeout_is_elapsed_requests_are_attempted_again
    half_open_cicuit!

    assert_circuit_closed
  end

  def test_until_success_threshold_is_reached_a_single_error_will_reopen_the_circuit
    half_open_cicuit!
    trigger_error!

    assert_circuit_opened
    assert_match(/State transition from open to half_open/, @strio.string)
  end

  def test_once_success_threshold_is_reached_only_error_threshold_will_open_the_circuit_again
    half_open_cicuit!

    assert_circuit_closed
    trigger_error!

    assert_circuit_closed
    trigger_error!

    assert_circuit_opened
  end

  def test_once_success_threshold_is_reached_only_error_threshold_will_open_the_circuit_again_without_timeout
    resource = Semian.register(
      :three,
      bulkhead: false,
      exceptions: [SomeError],
      error_threshold: 2,
      error_timeout: 5,
      success_threshold: 1,
    )
    half_open_cicuit!(resource)

    assert_circuit_closed(resource)
    trigger_error!(resource)

    assert_circuit_closed(resource)
    trigger_error!(resource)

    assert_circuit_opened(resource)
  ensure
    Semian.destroy(:three)
  end

  def test_reset_allow_to_close_the_circuit_and_forget_errors
    open_circuit!
    @resource.reset

    assert_match(/State transition from open to closed/, @strio.string)
    assert_circuit_closed
  end

  def test_errors_more_than_duration_apart_doesnt_open_circuit
    time_travel(-6) do
      trigger_error!

      assert_circuit_closed
    end

    trigger_error!

    assert_circuit_closed
  end

  def test_sparse_errors_open_circuit_when_without_timeout
    resource = Semian.register(
      :sparse_errors_open_circuit_when_without_timeout,
      bulkhead: false,
      exceptions: [SomeError],
      error_threshold: 3,
      error_timeout: 5,
      success_threshold: 1,
      error_threshold_timeout_enabled: false,
    )

    time_travel(-6) do
      trigger_error!(resource)

      assert_circuit_closed(resource)
    end

    time_travel(-1) do
      trigger_error!(resource)

      assert_circuit_closed(resource)
    end

    trigger_error!(resource)

    assert_circuit_opened(resource)
  ensure
    Semian.destroy(:sparse_errors_open_circuit_when_without_timeout)
  end

  def test_sparse_errors_dont_open_circuit
    resource = Semian.register(
      :sparse_errors_dont_open_circuit,
      bulkhead: false,
      exceptions: [SomeError],
      error_threshold: 3,
      error_timeout: 5,
      success_threshold: 1,
    )

    time_travel(-6) do
      trigger_error!(resource)

      assert_circuit_closed(resource)
    end

    time_travel(-1) do
      trigger_error!(resource)

      assert_circuit_closed(resource)
    end

    trigger_error!(resource)

    assert_circuit_closed(resource)
  ensure
    Semian.destroy(:sparse_errors_dont_open_circuit)
  end

  def test_request_allowed_query_doesnt_trigger_transitions
    resource = Semian.register(
      :test_request_allowed_query_doesnt_trigger_transitions,
      tickets: 1,
      exceptions: [SomeError],
      error_threshold: 2,
      error_timeout: 2,
      success_threshold: 1,
    )

    time_travel(-2) do
      open_circuit!(resource)

      refute_predicate(resource, :request_allowed?)
      assert_predicate(resource, :open?)
    end

    assert_predicate(resource, :request_allowed?)
    assert_predicate(resource, :open?)
  end

  def test_open_close_open_cycle
    resource = Semian.register(
      :open_close,
      tickets: 1,
      exceptions: [SomeError],
      error_threshold: 2,
      error_timeout: 5,
      success_threshold: 2,
    )

    open_circuit!(resource)

    assert_circuit_opened(resource)

    time_travel(resource.circuit_breaker.error_timeout + 1) do
      assert_circuit_closed(resource)

      assert_predicate(resource, :half_open?)
      assert_circuit_closed(resource)

      assert_predicate(resource, :closed?)

      open_circuit!(resource)

      assert_circuit_opened(resource)
    end

    time_travel(resource.circuit_breaker.error_timeout * 2 + 1) do
      assert_circuit_closed(resource)

      assert_predicate(resource, :half_open?)
      assert_circuit_closed(resource)

      assert_predicate(resource, :closed?)
    end
  end

  def test_open_close_open_cycle_when_without_timeout
    resource = Semian.register(
      :open_close,
      tickets: 1,
      exceptions: [SomeError],
      error_threshold: 2,
      error_timeout: 5,
      success_threshold: 2,
      error_threshold_timeout_enabled: false,
    )

    open_circuit!(resource)

    assert_circuit_opened(resource)

    time_travel(resource.circuit_breaker.error_timeout + 1) do
      assert_circuit_closed(resource)

      assert_predicate(resource, :half_open?)
      assert_circuit_closed(resource)

      assert_predicate(resource, :closed?)

      open_circuit!(resource)

      assert_circuit_opened(resource)
    end

    time_travel(resource.circuit_breaker.error_timeout * 2 + 1) do
      assert_circuit_closed(resource)

      assert_predicate(resource, :half_open?)
      assert_circuit_closed(resource)

      assert_predicate(resource, :closed?)
    end
  end

  def test_error_error_threshold_timeout_overrides_error_timeout_when_set_for_opening_circuits
    resource = Semian.register(
      :three,
      tickets: 1,
      exceptions: [SomeError],
      error_threshold: 3,
      error_timeout: 5,
      success_threshold: 1,
      error_threshold_timeout: 10,
    )

    time_travel(-6) do
      trigger_error!(resource)

      assert_circuit_closed(resource)
    end

    time_travel(-1) do
      trigger_error!(resource)

      assert_circuit_closed(resource)
    end

    trigger_error!(resource)

    assert_circuit_opened(resource)
  ensure
    Semian.destroy(:three)
  end

  def test_circuit_still_opens_when_passed_error_threshold_timeout_when_also_not_using_timeout
    resource = Semian.register(
      :three,
      tickets: 1,
      exceptions: [SomeError],
      error_threshold: 3,
      error_timeout: 5,
      success_threshold: 1,
      error_threshold_timeout: 10,
      error_threshold_timeout_enabled: false,
    )

    time_travel(-6) do
      trigger_error!(resource)

      assert_circuit_closed(resource)
    end

    time_travel(-1) do
      trigger_error!(resource)

      assert_circuit_closed(resource)
    end

    trigger_error!(resource)

    assert_circuit_opened(resource)
  ensure
    Semian.destroy(:three)
  end

  def test_error_threshold_timeout_defaults_to_error_timeout_when_not_specified
    resource = Semian.register(
      :error_threshold_timeout_defaults_to_error_timeout_when_not_specified,
      tickets: 1,
      exceptions: [SomeError],
      error_threshold: 3,
      error_timeout: 5,
      success_threshold: 1,
    )

    time_travel(-6) do
      trigger_error!(resource)

      assert_circuit_closed(resource)
    end

    time_travel(-1) do
      trigger_error!(resource)

      assert_circuit_closed(resource)
    end

    trigger_error!(resource)

    assert_circuit_closed(resource)
  ensure
    Semian.destroy(:error_threshold_timeout_defaults_to_error_timeout_when_not_specified)
  end

  def test_error_uses_defaults_when_using_timeout
    resource = Semian.register(
      :test_error_uses_defaults_when_using_timeout,
      tickets: 1,
      exceptions: [SomeError],
      error_threshold: 3,
      error_timeout: 5,
      success_threshold: 1,
      use_timeoout: true,
    )

    time_travel(-6) do
      trigger_error!(resource)

      assert_circuit_closed(resource)
    end

    time_travel(-1) do
      trigger_error!(resource)

      assert_circuit_closed(resource)
    end

    trigger_error!(resource)

    assert_circuit_closed(resource)
  ensure
    Semian.destroy(:test_error_uses_defaults_when_using_timeout)
  end

  def test_error_threshold_timeout_is_skipped_when_not_using_error_threshold_and_not_using_timeout
    resource = Semian.register(
      :three,
      tickets: 1,
      exceptions: [SomeError],
      error_threshold: 3,
      error_timeout: 5,
      success_threshold: 1,
      error_threshold_timeout_enabled: false,
    )

    time_travel(-6) do
      trigger_error!(resource)

      assert_circuit_closed(resource)
    end

    time_travel(-1) do
      trigger_error!(resource)

      assert_circuit_closed(resource)
    end

    trigger_error!(resource)

    assert_circuit_opened(resource)
  ensure
    Semian.destroy(:three)
  end

  def test_env_var_disables_circuit_breaker
    ENV["SEMIAN_CIRCUIT_BREAKER_DISABLED"] = "1"
    resource = Semian.register(
      :env_var_disables_circuit_breaker,
      tickets: 1,
      error_threshold: 1,
      error_timeout: 10,
      success_threshold: 1,
    )
    open_circuit!(resource)

    assert_circuit_closed(resource)
  ensure
    ENV.delete("SEMIAN_CIRCUIT_BREAKER_DISABLED")
  end

  class RawResource
    def timeout
      @timeout || 2
    end

    def with_resource_timeout(timeout)
      prev_timeout = @timeout
      @timeout = timeout
      yield
    ensure
      @timeout = prev_timeout
    end
  end

  def test_changes_resource_timeout_when_configured
    Semian.register(
      :resource_timeout,
      tickets: 1,
      exceptions: [SomeError],
      error_threshold: 2,
      error_timeout: 5,
      success_threshold: 1,
      half_open_resource_timeout: 0.123,
    )
    resource = Semian[:resource_timeout]

    half_open_cicuit!(resource)

    raw_resource = RawResource.new

    triggered = false
    resource.acquire(resource: raw_resource) do
      triggered = true

      assert_in_delta(0.123, raw_resource.timeout)
    end

    assert(triggered)
    assert_equal(2, raw_resource.timeout)
  end

  def test_doesnt_change_resource_timeout_when_closed
    Semian.register(
      :resource_timeout,
      tickets: 1,
      exceptions: [SomeError],
      error_threshold: 2,
      error_timeout: 5,
      success_threshold: 1,
      half_open_resource_timeout: 0.123,
    )
    resource = Semian[:resource_timeout]

    raw_resource = RawResource.new

    triggered = false
    resource.acquire(resource: raw_resource) do
      triggered = true

      assert_equal(2, raw_resource.timeout)
    end

    assert(triggered)
    assert_equal(2, raw_resource.timeout)
  end

  def test_doesnt_blow_up_when_configured_half_open_timeout_but_adapter_doesnt_support
    Semian.register(
      :resource_timeout,
      tickets: 1,
      exceptions: [SomeError],
      error_threshold: 2,
      error_timeout: 5,
      success_threshold: 1,
      half_open_resource_timeout: 0.123,
    )
    resource = Semian[:resource_timeout]

    raw_resource = Object.new

    triggered = false
    resource.acquire(resource: raw_resource) do
      triggered = true
    end

    assert(triggered)
  end

  class SomeErrorThatMarksCircuits < SomeError
    def marks_semian_circuits?
      true
    end
  end

  class SomeSubErrorThatDoesNotMarkCircuits < SomeErrorThatMarksCircuits
    def marks_semian_circuits?
      false
    end
  end

  def test_opens_circuit_when_error_has_marks_semian_circuits_equal_to_true
    2.times { trigger_error!(@resource, SomeErrorThatMarksCircuits) }

    assert_circuit_opened
  end

  def test_does_not_open_circuit_when_error_has_marks_semian_circuits_equal_to_false
    2.times { trigger_error!(@resource, SomeSubErrorThatDoesNotMarkCircuits) }

    assert_circuit_closed
  end

  def test_notify_state_transition
    name = :test_notify_state_transition

    events = []
    Semian.subscribe(:test_notify_state_transition) do |event, resource, _scope, _adapter, payload|
      if event == :state_change
        events << { name: resource.name, state: payload[:state] }
      end
    end

    # Creating a resource should generate a :closed notification.
    resource = Semian.register(
      name,
      tickets: 1,
      exceptions: [StandardError],
      error_threshold: 2,
      error_timeout: 1,
      success_threshold: 1,
    )

    assert_equal(1, events.length)
    assert_equal(name, events[0][:name])
    assert_equal(:closed, events[0][:state])

    # Acquiring a resource doesn't generate a transition.
    resource.acquire { nil }

    assert_equal(1, events.length)

    # error_threshold failures causes a transition to open.
    2.times { trigger_error!(resource) }

    assert_equal(2, events.length)
    assert_equal(name, events[1][:name])
    assert_equal(:open, events[1][:state])

    time_travel(3600) do
      # Acquiring the resource successfully generates a transition to half_open, then closed.
      resource.acquire { nil }
    end

    assert_equal(4, events.length)
    assert_equal(name, events[2][:name])
    assert_equal(:half_open, events[2][:state])
    assert_equal(name, events[3][:name])
    assert_equal(:closed, events[3][:state])
  ensure
    Semian.unsubscribe(:test_notify_state_transition)
  end

  def test_lumping_interval_prevents_rapid_error_accumulation
    resource = Semian.register(
      :lumping_test,
      bulkhead: false,
      exceptions: [SomeError],
      error_threshold: 3,
      error_timeout: 10,
      success_threshold: 1,
      lumping_interval: 2,
    )

    # Trigger an arbitrary number of errors within lumping interval
    6.times do
      trigger_error!(resource)
    end

    # Should not open circuit since errors are lumped
    assert_circuit_closed(resource)

    time_travel(3) do
      6.times do
        trigger_error!(resource)
      end

      assert_circuit_closed(resource)

      time_travel(3) do
        # A single error should open circuit because we have reached the error threshold
        trigger_error!(resource)

        assert_circuit_opened(resource)
      end
    end
  ensure
    Semian.destroy(:lumping_test)
  end

  def test_lumping_interval_respects_error_threshold
    resource = Semian.register(
      :lumping_threshold_test,
      bulkhead: false,
      exceptions: [SomeError],
      error_threshold: 2,
      error_timeout: 5,
      success_threshold: 1,
      lumping_interval: 1,
    )

    # First error
    trigger_error!(resource)

    assert_circuit_closed(resource)

    # Wait past lumping interval
    time_travel(2) do
      # Second error should open circuit
      trigger_error!(resource)

      assert_circuit_opened(resource)
    end
  ensure
    Semian.destroy(:lumping_threshold_test)
  end

  def test_lumping_interval_with_zero_value
    resource = Semian.register(
      :lumping_zero_test,
      bulkhead: false,
      exceptions: [SomeError],
      error_threshold: 2,
      error_timeout: 5,
      success_threshold: 1,
      lumping_interval: 0,
    )

    # First error
    trigger_error!(resource)

    assert_circuit_closed(resource)

    # Second error should open circuit immediately
    trigger_error!(resource)

    assert_circuit_opened(resource)
  ensure
    Semian.destroy(:lumping_zero_test)
  end

  def test_lumping_interval_cannot_be_greater_than_error_threshold_timeout
    error = assert_raises(ArgumentError) do
      Semian.register(
        :lumping_validation_test,
        force_config_validation: true,
        bulkhead: false,
        exceptions: [SomeError],
        error_threshold: 2,
        error_timeout: 5,
        error_threshold_timeout: 3,
        success_threshold: 1,
        lumping_interval: 4,
      )
    end

    assert_match("constraint violated, this circuit breaker can never open! lumping_interval * (error_threshold - 1) should be <= error_threshold_timeout", error.message)
  ensure
    Semian.destroy(:lumping_validation_test)
  end

  def test_circuit_breaker_with_invalid_success_threshold
    error = assert_raises(ArgumentError) do
      Semian.register(
        :testing_invalid_success,
        force_config_validation: true,
        circuit_breaker: true,
        success_threshold: 0,
        error_threshold: 2,
        error_timeout: 5,
        bulkhead: false,
      )
    end

    assert_match("success_threshold must be a positive integer", error.message)
  end

  def test_circuit_breaker_with_invalid_error_threshold
    error = assert_raises(ArgumentError) do
      Semian.register(
        :testing_invalid_error,
        force_config_validation: true,
        circuit_breaker: true,
        success_threshold: 2,
        error_threshold: 0,
        error_timeout: 5,
        bulkhead: false,
      )
    end

    assert_match("error_threshold must be a positive integer", error.message)
  end

  def test_circuit_breaker_with_invalid_error_timeout
    error = assert_raises(ArgumentError) do
      Semian.register(
        :testing_invalid_timeout,
        force_config_validation: true,
        circuit_breaker: true,
        success_threshold: 2,
        error_threshold: 2,
        error_timeout: -1,
        bulkhead: false,
      )
    end

    assert_match("error_timeout must be a positive number", error.message)
  end

  def test_circuit_breaker_with_invalid_lumping_interval
    error = assert_raises(ArgumentError) do
      Semian.register(
        :testing_invalid_lumping,
        force_config_validation: true,
        circuit_breaker: true,
        success_threshold: 2,
        error_threshold: 2,
        error_timeout: 5,
        lumping_interval: 10,
        error_threshold_timeout: 5,
        bulkhead: false,
      )
    end

    assert_match("constraint violated, this circuit breaker can never open! lumping_interval * (error_threshold - 1) should be <= error_threshold_timeout", error.message)
  end

  def test_circuit_breaker_with_missing_required_params
    error = assert_raises(ArgumentError) do
      Semian.register(
        :testing_missing_params,
        force_config_validation: true,
        circuit_breaker: true,
        success_threshold: 2,
        bulkhead: false,
      )
    end

    assert_match("Missing required arguments for Semian: [:error_threshold, :error_timeout]", error.message)
  end

  def test_half_open_resource_timeout_negative
    error = assert_raises(ArgumentError) do
      Semian.register(
        :invalid_half_open_resource_timeout,
        force_config_validation: true,
        tickets: 1,
        error_threshold: 2,
        error_timeout: 5,
        success_threshold: 1,
        half_open_resource_timeout: -1,
      )
    end
    assert_match("half_open_resource_timeout must be a positive number", error.message)
  end

  def test_lumping_interval_negative
    error = assert_raises(ArgumentError) do
      Semian.register(
        :invalid_lumping_interval,
        force_config_validation: true,
        tickets: 1,
        error_threshold: 2,
        error_timeout: 5,
        success_threshold: 1,
        lumping_interval: -1,
      )
    end
    assert_match("lumping_interval must be a positive number", error.message)
  end

  def test_lumping_interval_times_threshold_exceeds_error_threshold_timeout
    error = assert_raises(ArgumentError) do
      Semian.register(
        :invalid_lumping_times_threshold,
        force_config_validation: true,
        tickets: 1,
        error_threshold: 3,
        error_timeout: 5,
        success_threshold: 1,
        lumping_interval: 3,
        error_threshold_timeout: 4,
      )
    end

    assert_match("constraint violated, this circuit breaker can never open! lumping_interval * (error_threshold - 1) should be <= error_threshold_timeout", error.message)
  end

  def test_error_threshold_timeout_enabled_and_error_threshold_timeout_contradiction
    error = assert_raises(ArgumentError) do
      Semian.register(
        :contradiction_test,
        force_config_validation: true,
        tickets: 1,
        error_threshold: 2,
        error_timeout: 5,
        success_threshold: 1,
        error_threshold_timeout_enabled: false,
        error_threshold_timeout: 10,
      )
    end
    assert_match("error_threshold_timeout_enabled and error_threshold_timeout must not contradict each other", error.message)
  end

  # Dynamic Timeout Tests

  def test_dynamic_timeout_starts_at_minimum
    resource = Semian.register(
      :dynamic_timeout_min,
      bulkhead: false,
      exceptions: [SomeError],
      error_threshold: 2,
      dynamic_timeout: true,
      success_threshold: 1,
    )

    # Open the circuit
    open_circuit!(resource)

    assert_circuit_opened(resource)

    # Wait for minimum backoff time (500ms)
    time_travel(0.5 + 0.1) do
      assert_circuit_closed(resource) # Should be half-open and allow request
    end
  ensure
    Semian.destroy(:dynamic_timeout_min)
  end

  def test_dynamic_timeout_doubles_on_consecutive_failures
    resource = Semian.register(
      :dynamic_timeout_double,
      bulkhead: false,
      exceptions: [SomeError],
      error_threshold: 2,
      dynamic_timeout: true,
      success_threshold: 1,
    )

    # Open the circuit
    open_circuit!(resource)

    assert_circuit_opened(resource)

    # Wait for initial backoff (500ms) and trigger error in half-open state
    time_travel(0.6) do
      trigger_error!(resource) # Should transition to open again with doubled backoff

      assert_circuit_opened(resource)
    end

    # Should still be open after 0.5s (initial backoff)
    time_travel(1.1) do # 0.6 + 0.5 = 1.1 total
      assert_circuit_opened(resource)
    end

    # Should be half-open after 1s (doubled backoff)
    time_travel(1.7) do # 0.6 + 1.0 + 0.1 = 1.7 total
      assert_circuit_closed(resource) # half-open allows requests
    end
  ensure
    Semian.destroy(:dynamic_timeout_double)
  end

  def test_dynamic_timeout_exponential_then_linear
    resource = Semian.register(
      :dynamic_timeout_exp_then_linear,
      bulkhead: false,
      exceptions: [SomeError],
      error_threshold: 2,
      dynamic_timeout: true,
      success_threshold: 1,
    )

    # Open the circuit
    open_circuit!(resource)

    # Expected progression:
    # Exponential: 0.5 → 1 → 2 → 4 → 8 → 16 → 20 (capped at 20 instead of 32)
    # Linear: 20 → 21 → 22 → 23 → 24 → 25 ... → 60
    expected_progression = [0.5, 1, 2, 4, 8, 16, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 60]

    current_time = 0.0
    cb = resource.circuit_breaker

    expected_progression.each_with_index do |expected_timeout, index|
      # Skip first value (it's the initial state)
      next if index == 0

      # Wait for current backoff
      current_backoff = expected_progression[index - 1]
      current_time += current_backoff + 0.1

      time_travel(current_time) do
        # Should be half-open now
        assert_predicate(resource, :half_open?)

        # Trigger error to increase backoff
        trigger_error!(resource)

        assert_circuit_opened(resource)

        # Check that error_timeout matches expected progression
        assert_equal(
          expected_timeout,
          cb.error_timeout,
          "Expected timeout of #{expected_timeout} at index #{index}, got #{cb.error_timeout}",
        )
      end
    end
  ensure
    Semian.destroy(:dynamic_timeout_exp_then_linear)
  end

  def test_dynamic_timeout_to_linear_transition
    resource = Semian.register(
      :dynamic_timeout_linear_transition,
      bulkhead: false,
      exceptions: [SomeError],
      error_threshold: 2,
      dynamic_timeout: true,
      success_threshold: 1,
    )

    cb = resource.circuit_breaker

    # Open the circuit
    open_circuit!(resource)

    assert_equal(0.5, cb.error_timeout)

    # Get to 16s (still exponential)
    timeouts = [0.5, 1, 2, 4, 8, 16]
    current_time = 0.0

    timeouts[1..-1].each do |expected_next|
      current_time += cb.error_timeout + 0.1
      time_travel(current_time) do
        trigger_error!(resource)

        assert_equal(expected_next, cb.error_timeout)
      end
    end

    # Next transition should cap at 20s (not 32s)
    current_time += cb.error_timeout + 0.1
    time_travel(current_time) do
      trigger_error!(resource)

      assert_equal(20, cb.error_timeout, "Should cap at 20s instead of doubling to 32s")
    end

    # After 20s, should switch to linear increments of 1s
    [21, 22, 23].each do |expected_next|
      current_time += cb.error_timeout + 0.1
      time_travel(current_time) do
        trigger_error!(resource)

        assert_equal(expected_next, cb.error_timeout, "Should increment by 1s in linear phase")
      end
    end
  ensure
    Semian.destroy(:dynamic_timeout_linear_transition)
  end

  def test_dynamic_timeout_caps_at_60_seconds
    resource = Semian.register(
      :dynamic_timeout_caps_at_60,
      bulkhead: false,
      exceptions: [SomeError],
      error_threshold: 2,
      dynamic_timeout: true,
      success_threshold: 1,
    )

    cb = resource.circuit_breaker

    # Open the circuit and get to 56s
    open_circuit!(resource)

    # Fast forward through the progression to get near the cap
    # We need to go through: 0.5 → 1 → 2 → 4 → 8 → 16 → 20, then increment by 1 until we reach near 60
    progression = [0.5, 1, 2, 4, 8, 16, 20]
    # Add linear progression from 20 to 59
    current = 20
    while current < 59
      current += 1
      progression << current
    end
    current_time = 0.0

    progression[1..-1].each do |expected|
      current_time += cb.error_timeout + 0.1
      time_travel(current_time) do
        trigger_error!(resource)

        assert_equal(expected, cb.error_timeout)
      end
    end

    # Next should cap at 60
    current_time += cb.error_timeout + 0.1
    time_travel(current_time) do
      trigger_error!(resource)

      assert_equal(60, cb.error_timeout, "Should cap at 60s")
    end

    # Should stay at 60 on subsequent failures
    current_time += cb.error_timeout + 0.1
    time_travel(current_time) do
      trigger_error!(resource)

      assert_equal(60, cb.error_timeout, "Should remain capped at 60s")
    end
  ensure
    Semian.destroy(:dynamic_timeout_caps_at_60)
  end

  def test_dynamic_timeout_resets_on_success
    resource = Semian.register(
      :dynamic_timeout_reset,
      bulkhead: false,
      exceptions: [SomeError],
      error_threshold: 2,
      dynamic_timeout: true,
      success_threshold: 2,
    )

    # Open the circuit
    open_circuit!(resource)

    # Wait for initial backoff and fail again
    time_travel(0.6) do
      trigger_error!(resource) # Should double backoff to 1s
    end

    # Wait for doubled backoff and succeed
    time_travel(1.7) do
      # Half-open state
      assert_circuit_closed(resource)  # First success
      assert_circuit_closed(resource)  # Second success - should close circuit
    end

    # Open circuit again
    open_circuit!(resource)

    # Backoff should have reset to minimum (500ms)
    time_travel(2.3) do # 1.7 + 0.5 + 0.1
      assert_circuit_closed(resource) # Should be half-open
    end
  ensure
    Semian.destroy(:dynamic_timeout_reset)
  end

  def test_dynamic_timeout_and_error_timeout_are_mutually_exclusive
    error = assert_raises(ArgumentError) do
      Semian.register(
        :dynamic_and_fixed_timeout,
        force_config_validation: true,
        bulkhead: false,
        exceptions: [SomeError],
        error_threshold: 2,
        error_timeout: 5,
        dynamic_timeout: true,
        success_threshold: 1,
      )
    end

    assert_match("error_timeout and dynamic_timeout are mutually exclusive", error.message)
  ensure
    begin
      Semian.destroy(:dynamic_and_fixed_timeout)
    rescue
      nil
    end
  end

  def test_dynamic_timeout_does_not_require_error_timeout
    resource = Semian.register(
      :dynamic_no_timeout,
      force_config_validation: true,
      bulkhead: false,
      exceptions: [SomeError],
      error_threshold: 2,
      dynamic_timeout: true,
      success_threshold: 1,
    )

    assert_predicate(resource, :closed?)
    open_circuit!(resource)

    assert_predicate(resource, :open?)
  ensure
    Semian.destroy(:dynamic_no_timeout)
  end

  def test_dynamic_timeout_with_error_threshold_timeout
    resource = Semian.register(
      :dynamic_with_threshold_timeout,
      bulkhead: false,
      exceptions: [SomeError],
      error_threshold: 3,
      dynamic_timeout: true,
      error_threshold_timeout: 10,
      success_threshold: 1,
    )

    # Errors outside threshold window shouldn't open circuit
    time_travel(-11) do
      trigger_error!(resource)
    end

    time_travel(-5) do
      trigger_error!(resource)
    end

    trigger_error!(resource)

    # Only 2 errors within window, circuit should remain closed
    assert_circuit_closed(resource)

    # Add one more error to open circuit
    trigger_error!(resource)

    assert_circuit_opened(resource)

    # Wait for exponential backoff (500ms)
    time_travel(0.6) do
      assert_circuit_closed(resource) # Should be half-open
    end
  ensure
    Semian.destroy(:dynamic_with_threshold_timeout)
  end

  def test_dynamic_timeout_logging
    resource = Semian.register(
      :dynamic_timeout_logging,
      bulkhead: false,
      exceptions: [SomeError],
      error_threshold: 2,
      dynamic_timeout: true,
      success_threshold: 1,
    )

    open_circuit!(resource)

    # Check that logs contain dynamic timeout information
    assert_match(/dynamic_timeout=true/, @strio.string)
    assert_match(/error_timeout=0.5/, @strio.string)

    # Fail in half-open state
    time_travel(0.6) do
      trigger_error!(resource)
    end

    # Check updated backoff in logs
    assert_match(/error_timeout=1/, @strio.string)
  ensure
    Semian.destroy(:dynamic_timeout_logging)
  end

  def test_dynamic_timeout_multiple_consecutive_opens
    resource = Semian.register(
      :dynamic_timeout_multiple_opens,
      bulkhead: false,
      exceptions: [SomeError],
      error_threshold: 2,
      dynamic_timeout: true,
      success_threshold: 1,
    )

    # Test both exponential and linear phases
    # Exponential phase: 0.5 → 1 → 2 → 4 → 8 → 16 → 20
    # Linear phase: 20 → 21 → 22 → 23
    expected_backoffs = [0.5, 1.0, 2.0, 4.0, 8.0, 16.0, 20.0, 21.0, 22.0, 23.0]
    current_time = 0.0

    # Open initially
    open_circuit!(resource)

    cb = resource.circuit_breaker

    assert_equal(0.5, cb.error_timeout)

    expected_backoffs[1..-1].each_with_index do |next_expected, index|
      # Wait for current backoff period
      current_backoff = expected_backoffs[index]
      current_time += current_backoff + 0.1

      time_travel(current_time) do
        # Should be half-open
        assert_predicate(resource, :half_open?)

        # Fail again to increase backoff
        trigger_error!(resource)

        # Should be open with increased backoff
        assert_circuit_opened(resource)

        # Check that error_timeout matches expected value
        assert_equal(
          next_expected,
          cb.error_timeout,
          "Expected #{next_expected} at iteration #{index + 1}, got #{cb.error_timeout}",
        )
      end
    end
  ensure
    Semian.destroy(:dynamic_timeout_multiple_opens)
  end

  def test_dynamic_timeout_state_tracking
    resource = Semian.register(
      :dynamic_timeout_state_tracking,
      bulkhead: false,
      exceptions: [SomeError],
      error_threshold: 2,
      dynamic_timeout: true,
      success_threshold: 3,
    )

    cb = resource.circuit_breaker

    # Initial state
    assert_equal(0.5, cb.error_timeout)

    # Open circuit
    open_circuit!(resource)

    # error_timeout should still be at initial value since it's the first open
    assert_equal(0.5, cb.error_timeout)

    # Fail in half-open
    time_travel(0.6) do
      trigger_error!(resource)

      # error_timeout should have doubled
      assert_equal(1.0, cb.error_timeout)
    end

    # Succeed to close circuit
    time_travel(1.7) do
      3.times { assert_circuit_closed(resource) }

      # error_timeout should reset to initial value
      assert_equal(0.5, cb.error_timeout)
    end
  ensure
    Semian.destroy(:dynamic_timeout_state_tracking)
  end
end
