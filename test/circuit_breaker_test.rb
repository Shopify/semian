# frozen_string_literal: true

require "test_helper"

class TestCircuitBreaker < Minitest::Test
  include CircuitBreakerHelper
  include TimeHelper

  def setup
    destroy_all_semian_resources
  end

  def test_acquire_yield_when_the_circuit_is_closed
    resource = Semian.register(
      :circuit_is_closed,
      bulkhead: false,
      exceptions: [SomeError],
      error_threshold: 2,
      error_timeout: 5,
      success_threshold: 1,
    )

    assert_circuit_closed(resource)
  end

  def test_acquire_raises_circuit_open_error_when_the_circuit_is_open
    resource = Semian.register(
      :circuit_is_open_raise_error,
      bulkhead: false,
      exceptions: [SomeError],
      error_threshold: 2,
      error_timeout: 5,
      success_threshold: 1,
    )
    open_circuit!(resource)
    assert_raises(Semian::OpenCircuitError) do
      resource.acquire { 1 + 1 }
    end
  end

  def test_acquire_log_message_when_the_circuit_is_open
    resource = Semian.register(
      :circuit_is_open_log_message,
      bulkhead: false,
      exceptions: [SomeError],
      error_threshold: 1,
      error_timeout: 5,
      success_threshold: 1,
    )
    assert_log_message_match(/State transition from closed to open/, level: :info) do
      open_circuit!(resource, error_count: 3)
    rescue Semian::OpenCircuitError
    end
  end

  def test_last_error_message_is_logged_when_circuit_opens
    resource = Semian.register(
      :circuit_is_open_last_error,
      bulkhead: false,
      exceptions: [SomeError],
      error_threshold: 1,
      error_timeout: 5,
      success_threshold: 1,
    )
    assert_log_message_match(/last_error_message="some error message 0"/, level: :info) do
      3.times do |i|
        resource.acquire { raise SomeError, "some error message #{i}" }
      rescue SomeError
      end
    rescue Semian::OpenCircuitError
    end
  end

  def test_after_error_threshold_the_circuit_is_open
    resource = Semian.register(
      :circuit_is_open_after_error_threshold,
      bulkhead: false,
      exceptions: [SomeError],
      error_threshold: 3,
      error_timeout: 5,
      success_threshold: 1,
    )
    open_circuit!(resource, error_count: 3)

    assert_circuit_opened(resource)
  end

  def test_after_error_timeout_is_elapsed_requests_are_attempted_again
    resource = Semian.register(
      :circuit_is_open_after_error_timeout_try_again,
      bulkhead: false,
      exceptions: [SomeError],
      error_threshold: 3,
      error_timeout: 5,
      success_threshold: 1,
    )
    half_open_cicuit!(resource, error_count: 3, backwards_time_travel: 10)

    assert_circuit_closed(resource)
  end

  def test_until_success_threshold_is_reached_a_single_error_will_reopen_the_circuit
    resource = Semian.register(
      :circuit_is_open_success_single_error,
      bulkhead: false,
      exceptions: [SomeError],
      error_threshold: 3,
      error_timeout: 5,
      success_threshold: 1,
    )
    half_open_cicuit!(resource, error_count: 3, backwards_time_travel: 10)
    expected = /State transition from open to half_open.*State transition from half_open to open/m
    assert_log_message_match(expected) do
      trigger_error!(resource)
    end

    assert_circuit_opened(resource)
  end

  def test_once_success_threshold_is_reached_only_error_threshold_will_open_the_circuit_again
    resource = Semian.register(
      :circuit_once_success_threshold_is_reached_only_error_threshold_will_open_the_circuit_again,
      bulkhead: false,
      exceptions: [SomeError],
      error_threshold: 3,
      error_timeout: 5,
      success_threshold: 1,
    )
    half_open_cicuit!(resource, error_count: 3, backwards_time_travel: 10)

    assert_circuit_closed(resource)
    trigger_error!(resource)

    assert_circuit_closed(resource)
    trigger_error!(resource)

    assert_circuit_closed(resource)
  end

  def test_once_success_threshold_is_reached_only_error_threshold_will_open_the_circuit_again_without_timeout
    resource = Semian.register(
      :error_threshold_timeout_enabled,
      bulkhead: false,
      exceptions: [SomeError],
      error_threshold: 2,
      error_timeout: 5,
      success_threshold: 1,
      error_threshold_timeout_enabled: false,
    )
    half_open_cicuit!(resource)

    assert_circuit_closed(resource)
    trigger_error!(resource)

    assert_circuit_closed(resource)
    trigger_error!(resource)

    assert_circuit_opened(resource)
  ensure
    Semian.destroy(:error_threshold_timeout_enabled)
  end

  def test_disabled_error_threshold_to_ignore_error_timeout
    resource = Semian.register(
      :errors_more_than_duration_apart_doesnt_open_circuit,
      bulkhead: false,
      exceptions: [SomeError],
      error_threshold: 2,
      error_timeout: 5,
      success_threshold: 1,
      error_threshold_timeout_enabled: false,
    )

    time_travel(-10) do
      trigger_error!(resource)          # > @errors.size == 1

      assert_circuit_closed(resource)
    end

    trigger_error!(resource)            # > @errors.size == 2 and error_timeout < Time.now - @errors.first

    assert_circuit_opened(resource)
  end

  def test_reset_errors_after_success_event_without_timeout
    resource = Semian.register(
      :error_threshold_timeout_enabled,
      bulkhead: false,
      exceptions: [SomeError],
      error_threshold: 2,
      error_timeout: 5,
      success_threshold: 1,
      error_threshold_timeout_enabled: false,
    )
    time_travel(-10) do
      open_circuit!(resource, error_count: 2)

      assert_circuit_opened(resource)
    end

    assert_circuit_closed(resource)
    trigger_error!(resource)

    assert_circuit_closed(resource)
  end

  def test_reset_allow_to_close_the_circuit_and_forget_errors
    resource = Semian.register(
      :reset_allow_to_close_the_circuit_and_forget_errors,
      bulkhead: false,
      exceptions: [SomeError],
      error_threshold: 2,
      error_timeout: 5,
      success_threshold: 1,
    )
    open_circuit!(resource)
    assert_log_message_match(/State transition from open to closed/) do
      resource.reset
    end

    assert_circuit_closed(resource)
  end

  def test_errors_more_than_duration_apart_doesnt_open_circuit
    resource = Semian.register(
      :errors_more_than_duration_apart_doesnt_open_circuit,
      bulkhead: false,
      exceptions: [SomeError],
      error_threshold: 2,
      error_timeout: 5,
      success_threshold: 1,
    )

    time_travel(-6) do
      trigger_error!(resource)

      assert_circuit_closed(resource)
    end
    trigger_error!(resource)

    assert_circuit_closed(resource)
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
      trigger_error!(resource)           # > @errors.size == 1

      assert_circuit_closed(resource)
    end

    time_travel(-1) do
      trigger_error!(resource)           # > @errors.size == 2

      assert_circuit_closed(resource)
    end

    trigger_error!(resource)             # > @errors.size == 3 and error_timeout < time_window - @errors.first

    assert_circuit_opened(resource)
  ensure
    Semian.destroy(:sparse_errors_open_circuit_when_without_timeout)
  end

  def test_sparse_errors_dont_open_circuit
    resource = Semian.register(
      :circuit_sparse_errors_dont_open_circuit,
      bulkhead: false,
      exceptions: [SomeError],
      error_threshold: 3,
      error_timeout: 5,
      success_threshold: 1,
    )

    time_travel(-6) do
      trigger_error!(resource)           # > @errors.size == 1

      assert_circuit_closed(resource)
    end

    time_travel(-1) do
      trigger_error!(resource)           # > @errors.size == 1

      assert_circuit_closed(resource)
    end

    trigger_error!(resource)             # > @errors.size == 2

    assert_circuit_closed(resource)
  end

  def test_request_allowed_query_doesnt_trigger_transitions
    resource = Semian.register(
      :circuit_request_allowed_query_doesnt_trigger_transitions,
      bulkhead: false,
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
      bulkhead: false,
      exceptions: [SomeError],
      error_threshold: 2,
      error_timeout: 5,
      success_threshold: 2,
    )

    open_circuit!(resource, error_count: 2)

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
      :open_close_without_timeout,
      bulkhead: false,
      exceptions: [SomeError],
      error_threshold: 2,
      error_timeout: 5,
      success_threshold: 2,
      error_threshold_timeout_enabled: false,
    )

    open_circuit!(resource, error_count: 2)

    assert_circuit_opened(resource)

    time_travel(resource.circuit_breaker.error_timeout + 1) do
      assert_circuit_closed(resource)

      assert_predicate(resource, :half_open?)
      assert_circuit_closed(resource)

      assert_predicate(resource, :closed?)

      open_circuit!(resource, error_count: 2)

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
      :error_threshold_timeout_overrides_error_timeout_when_set_for_opening_circuits,
      bulkhead: false,
      exceptions: [SomeError],
      error_threshold: 3,
      error_timeout: 5,
      success_threshold: 1,
      error_threshold_timeout: 10,
    )

    time_travel(-6) do
      trigger_error!(resource)           # > @errors.size == 1

      assert_circuit_closed(resource)
    end

    time_travel(-1) do
      trigger_error!(resource)           # > @errors.size == 2

      assert_circuit_closed(resource)
    end

    trigger_error!(resource)             # > @errors.size == 3

    assert_circuit_opened(resource)
  ensure
    Semian.destroy(:error_threshold_timeout_overrides_error_timeout_when_set_for_opening_circuits)
  end

  def test_circuit_still_opens_when_passed_error_threshold_timeout_when_also_not_using_timeout
    resource = Semian.register(
      :circuit_still_opens_when_passed_error_threshold_timeout_when_also_not_using_timeout,
      bulkhead: false,
      exceptions: [SomeError],
      error_threshold: 3,
      error_timeout: 5,
      success_threshold: 1,
      error_threshold_timeout: 10,
      error_threshold_timeout_enabled: false,
    )

    time_travel(-6) do
      trigger_error!(resource)           # > @errors.size == 1

      assert_circuit_closed(resource)
    end

    time_travel(-1) do
      trigger_error!(resource)           # > @errors.size == 2

      assert_circuit_closed(resource)
    end

    trigger_error!(resource)             # > @errors.size == 3

    assert_circuit_opened(resource)
  end

  def test_error_threshold_timeout_defaults_to_error_timeout_when_not_specified
    resource = Semian.register(
      :error_threshold_timeout_defaults_to_error_timeout_when_not_specified,
      bulkhead: false,
      exceptions: [SomeError],
      error_threshold: 3,
      error_timeout: 5,
      success_threshold: 1,
    )

    time_travel(-6) do
      trigger_error!(resource)           # > @errors.size == 1

      assert_circuit_closed(resource)
    end

    time_travel(-1) do
      trigger_error!(resource)           # > @errors.size == 2

      assert_circuit_closed(resource)
    end

    trigger_error!(resource)             # > @errors.size == 2

    assert_circuit_closed(resource)
  ensure
    Semian.destroy(:error_threshold_timeout_defaults_to_error_timeout_when_not_specified)
  end

  def test_error_uses_defaults_when_using_timeout
    resource = Semian.register(
      :error_uses_defaults_when_using_timeout,
      bulkhead: false,
      exceptions: [SomeError],
      error_threshold: 3,
      error_timeout: 5,
      success_threshold: 1,
      error_threshold_timeout_enabled: true,
    )

    time_travel(-6) do
      trigger_error!(resource)             # > @errors.size == 1

      assert_circuit_closed(resource)
    end

    time_travel(-1) do
      trigger_error!(resource)             # > @errors.size == 2

      assert_circuit_closed(resource)
    end

    trigger_error!(resource)               # > @errors.size == 2

    assert_circuit_closed(resource)
  ensure
    Semian.destroy(:test_error_uses_defaults_when_using_timeout)
  end

  def test_error_threshold_timeout_is_skipped_when_not_using_error_threshold_and_not_using_timeout
    resource = Semian.register(
      :error_thresshold_skip_when_not_using_threshold,
      bulkhead: false,
      exceptions: [SomeError],
      error_threshold: 3,
      error_timeout: 5,
      success_threshold: 1,
      error_threshold_timeout_enabled: false,
    )

    time_travel(-6) do
      trigger_error!(resource)             # > @errors.size == 1

      assert_circuit_closed(resource)
    end

    time_travel(-1) do
      trigger_error!(resource)             # > @errors.size == 2

      assert_circuit_closed(resource)
    end

    trigger_error!(resource)               # > @errors.size == 3

    assert_circuit_opened(resource)
  ensure
    Semian.destroy(:error_thresshold_skip_when_not_using_threshold)
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
    resource = Semian.register(
      :resource_timeout,
      bulkhead: false,
      exceptions: [SomeError],
      error_threshold: 2,
      error_timeout: 5,
      success_threshold: 1,
      half_open_resource_timeout: 0.123,
    )
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
    resource = Semian.register(
      :resource_timeout,
      bulkhead: false,
      exceptions: [SomeError],
      error_threshold: 2,
      error_timeout: 5,
      success_threshold: 1,
      half_open_resource_timeout: 0.123,
    )

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
    resource = Semian.register(
      :resource_timeout,
      bulkhead: false,
      exceptions: [SomeError],
      error_threshold: 2,
      error_timeout: 5,
      success_threshold: 1,
      half_open_resource_timeout: 0.123,
    )

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
    resource = Semian.register(
      :opens_circuit_when_error_has_marks_semian_circuits_equal_to_true,
      bulkhead: false,
      exceptions: [SomeError],
      error_threshold: 2,
      error_timeout: 5,
      success_threshold: 1,
    )
    2.times { trigger_error!(resource, error: SomeErrorThatMarksCircuits) }

    assert_circuit_opened(resource)
  end

  def test_does_not_open_circuit_when_error_has_marks_semian_circuits_equal_to_false
    resource = Semian.register(
      :opens_circuit_when_error_has_marks_semian_circuits_equal_to_true,
      bulkhead: false,
      exceptions: [SomeError],
      error_threshold: 2,
      error_timeout: 5,
      success_threshold: 1,
    )
    2.times { trigger_error!(resource, error: SomeSubErrorThatDoesNotMarkCircuits) }

    assert_circuit_closed(resource)
  end

  def test_notify_state_transition
    events = []
    Semian.subscribe(:test_notify_state_transition) do |event, resource, _scope, _adapter, payload|
      if event == :state_change
        events << { name: resource.name, state: payload[:state] }
      end
    end

    # Creating a resource should generate a :closed notification.
    resource = Semian.register(
      :test_notify_state_transition,
      bulkhead: false,
      exceptions: [StandardError],
      error_threshold: 2,
      error_timeout: 1,
      success_threshold: 1,
    )

    assert_equal(1, events.length)
    assert_equal(:test_notify_state_transition, events[0][:name])
    assert_equal(:closed, events[0][:state])

    # Acquiring a resource doesn't generate a transition.
    resource.acquire { nil }

    assert_equal(1, events.length)

    # error_threshold failures causes a transition to open.
    2.times { trigger_error!(resource) }

    assert_equal(2, events.length)
    assert_equal(:test_notify_state_transition, events[1][:name])
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
end
