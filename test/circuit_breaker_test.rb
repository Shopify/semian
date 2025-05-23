# frozen_string_literal: true

require "test_helper"

class TestCircuitBreaker < Minitest::Test
  include CircuitBreakerHelper
  include TimeHelper

  def setup
    @strio = StringIO.new
    Semian.logger = Logger.new(@strio)
    destroy_all_semian_resources
    Semian.register(
      :testing,
      tickets: 1,
      exceptions: [SomeError],
      error_threshold: 2,
      error_timeout: 5,
      success_threshold: 1,
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
      error_threshold_timeout_enabled: false,
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
      :testing,
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
        bulkhead: false,
        exceptions: [SomeError],
        error_threshold: 2,
        error_timeout: 5,
        error_threshold_timeout: 3,
        success_threshold: 1,
        lumping_interval: 4,
      )
    end

    assert_match(/lumping_interval \(4\) must be less than error_threshold_timeout \(3\)/, error.message)
  ensure
    Semian.destroy(:lumping_validation_test)
  end
end
