require 'test_helper'

class TestErrorRateCircuitBreaker < Minitest::Test
  include CircuitBreakerHelper

  def setup
    @strio = StringIO.new
    Semian.logger = Logger.new @strio
    begin
      Semian.destroy(:testing)
    rescue
      nil
    end
    @resource = ::Semian::ErrorRateCircuitBreaker.new(:testing,
                                                      exceptions: [SomeError],
                                                      error_percent_threshold: 0.5,
                                                      error_timeout: 1,
                                                      time_window: 2,
                                                      minimum_request_volume: 2,
                                                      implementation: ::Semian::ThreadSafe,
                                                      success_threshold: 1,
                                                      half_open_resource_timeout: nil,
                                                      time_source: -> { Time.now.to_f * 1000 })
      Timecop.return
  end

  def teardown
    Timecop.return
  end

  def half_open_circuit(resource = @resource)
    Timecop.travel(-1.1) do
      open_circuit!(resource)
      assert_circuit_opened(resource)
    end
    assert resource.transition_to_half_open?, 'Expect breaker to be half-open'
  end

  def test_error_threshold_must_be_between_0_and_1
    assert_raises RuntimeError do
      ::Semian::ErrorRateCircuitBreaker.new(:testing,
                                            exceptions: [SomeError],
                                            error_percent_threshold: 1.0,
                                            error_timeout: 1,
                                            time_window: 2,
                                            minimum_request_volume: 2,
                                            implementation: ::Semian::ThreadSafe,
                                            success_threshold: 1,
                                            half_open_resource_timeout: nil)
    end

    assert_raises RuntimeError do
      ::Semian::ErrorRateCircuitBreaker.new(:testing,
                                            exceptions: [SomeError],
                                            error_percent_threshold: 0.0,
                                            error_timeout: 1,
                                            time_window: 2,
                                            minimum_request_volume: 2,
                                            implementation: ::Semian::ThreadSafe,
                                            success_threshold: 1,
                                            half_open_resource_timeout: nil)
    end
  end

  def test_acquire_yield_when_the_circuit_is_closed
    block_called = false
    @resource.acquire { block_called = true }
    assert_equal true, block_called
  end

  def test_acquire_raises_circuit_open_error_when_the_circuit_is_open
    open_circuit!
    assert_raises Semian::OpenCircuitError do
      @resource.acquire { 1 + 1 }
    end
    assert_match(/State transition from closed to open/, @strio.string)
    assert_match(/minimum_request_volume=2/, @strio.string)
    assert_match(/time_window_ms=2000/, @strio.string)
    assert_match(/error_count_percent=0\.5/, @strio.string)
  end

  def test_after_error_threshold_the_circuit_is_open
    open_circuit!
    assert_circuit_opened
  end

  def test_after_error_timeout_is_elapsed_requests_are_attempted_again
    half_open_circuit
    assert_circuit_closed
  end

  def test_until_success_threshold_is_reached_a_single_error_will_reopen_the_circuit
    half_open_circuit
    trigger_error!
    assert_circuit_opened
  end

  def test_once_success_threshold_is_reached_only_error_threshold_will_open_the_circuit_again
    half_open_circuit
    assert_circuit_closed_elapse_time(@resource, 0.1) # one success
    assert_circuit_closed_elapse_time(@resource, 0.1) # two success
    trigger_error_elapse_time!(@resource, 0.11) # one failure
    trigger_error_elapse_time!(@resource, 0.11) # two failures (>50%)
    assert_circuit_opened
  end

  def test_reset_allow_to_close_the_circuit_and_forget_errors
    open_circuit!
    @resource.reset
    assert_match(/State transition from open to closed/, @strio.string)
    assert_circuit_closed
  end

  def test_errors_more_than_duration_apart_doesnt_open_circuit
    # allow time for error to slide off time window
    Timecop.travel(-2) do
      trigger_error!
    end
    trigger_error!
    assert_circuit_closed
  end

  def test_errors_under_threshold_doesnt_open_circuit
    # 60% success rate
    Timecop.travel(-2) do
      @resource.acquire do
        Timecop.travel(-1)
        1 + 1
      end

      @resource.acquire do
        Timecop.return
        1 + 1
      end
    end
    trigger_error!
    trigger_error!
    assert_circuit_closed
  end

  def test_request_allowed_query_doesnt_trigger_transitions
    Timecop.travel(-1.1) do
      open_circuit!
      refute_predicate @resource, :request_allowed?
      assert_predicate @resource, :open?
    end
    assert_predicate @resource, :request_allowed?
    assert_predicate @resource, :open?
  end

  def test_open_close_open_cycle
    resource = ::Semian::ErrorRateCircuitBreaker.new(:testing,
                                                     exceptions: [SomeError],
                                                     error_percent_threshold: 0.5,
                                                     error_timeout: 1,
                                                     time_window: 2,
                                                     minimum_request_volume: 2,
                                                     implementation: ::Semian::ThreadSafe,
                                                     success_threshold: 2,
                                                     half_open_resource_timeout: nil,
                                                     time_source: -> {Time.now.to_f * 1000})
    Timecop.travel(-1.1) do
      open_circuit!(resource)
      assert_circuit_opened(resource)
    end

    assert_circuit_closed(resource)

    assert resource.half_open?

    assert_circuit_closed_elapse_time(resource, 0.1)

    assert resource.closed?

    open_circuit!(resource, 1, 1)
    assert_circuit_opened(resource)

    Timecop.travel(1.1) do
      assert_circuit_closed(resource)

      assert resource.half_open?
      assert_circuit_closed(resource)

      assert resource.closed?
    end
  end

  def test_env_var_disables_circuit_breaker
    ENV['SEMIAN_CIRCUIT_BREAKER_DISABLED'] = '1'
    open_circuit!
    assert_circuit_closed
  ensure
    ENV.delete('SEMIAN_CIRCUIT_BREAKER_DISABLED')
  end

  def test_semian_wide_env_var_disables_circuit_breaker
    ENV['SEMIAN_DISABLED'] = '1'
    open_circuit!
    assert_circuit_closed
  ensure
    ENV.delete('SEMIAN_DISABLED')
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
    resource = ::Semian::ErrorRateCircuitBreaker.new(:resource_timeout,
                                                     exceptions: [SomeError],
                                                     error_percent_threshold: 0.5,
                                                     error_timeout: 1,
                                                     time_window: 2,
                                                     minimum_request_volume: 2,
                                                     implementation: ::Semian::ThreadSafe,
                                                     success_threshold: 2,
                                                     half_open_resource_timeout: 0.123,
                                                     time_source: -> { Time.now.to_f * 1000 })

    half_open_circuit(resource)
    assert_circuit_closed(resource)
    assert resource.half_open?

    raw_resource = RawResource.new

    triggered = false
    resource.acquire(raw_resource) do
      triggered = true
      assert_equal 0.123, raw_resource.timeout
    end

    assert triggered
    assert_equal 2, raw_resource.timeout
  end

  def test_doesnt_change_resource_timeout_when_closed
    resource = ::Semian::ErrorRateCircuitBreaker.new(:resource_timeout,
                                                     exceptions: [SomeError],
                                                     error_percent_threshold: 0.5,
                                                     error_timeout: 1,
                                                     time_window: 2,
                                                     minimum_request_volume: 2,
                                                     implementation: ::Semian::ThreadSafe,
                                                     success_threshold: 2,
                                                     half_open_resource_timeout: 0.123,
                                                     time_source: -> { Time.now.to_f * 1000 })

    raw_resource = RawResource.new

    triggered = false
    resource.acquire(raw_resource) do
      triggered = true
      assert_equal 2, raw_resource.timeout
    end

    assert triggered
    assert_equal 2, raw_resource.timeout
  end

  def test_doesnt_blow_up_when_configured_half_open_timeout_but_adapter_doesnt_support
    resource = ::Semian::ErrorRateCircuitBreaker.new(:resource_timeout,
                                                     exceptions: [SomeError],
                                                     error_percent_threshold: 0.5,
                                                     error_timeout: 1,
                                                     time_window: 2,
                                                     minimum_request_volume: 2,
                                                     implementation: ::Semian::ThreadSafe,
                                                     success_threshold: 2,
                                                     half_open_resource_timeout: 0.123,
                                                     time_source: -> { Time.now.to_f * 1000 })

    raw_resource = Object.new

    triggered = false
    resource.acquire(raw_resource) do
      triggered = true
    end

    assert triggered
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
        events << {name: resource.name, state: payload[:state]}
      end
    end

    # Creating a resource should generate a :closed notification.
    resource = ::Semian::ErrorRateCircuitBreaker.new(name,
                                                     exceptions: [SomeError],
                                                     error_percent_threshold: 0.6666,
                                                     error_timeout: 1,
                                                     time_window: 2,
                                                     minimum_request_volume: 2,
                                                     implementation: ::Semian::ThreadSafe,
                                                     success_threshold: 1,
                                                     half_open_resource_timeout: 0.123,
                                                     time_source: -> { Time.now.to_f * 1000 })
    assert_equal(1, events.length)
    assert_equal(name, events[0][:name])
    assert_equal(:closed, events[0][:state])

    # Acquiring a resource doesn't generate a transition.
    assert_circuit_closed_elapse_time(resource, 0.1)
    assert_equal(1, events.length)

    # error_threshold_percent failures causes a transition to open.
    2.times { trigger_error_elapse_time!(resource, 0.12) }
    assert_equal(2, events.length)
    assert_equal(name, events[1][:name])
    assert_equal(:open, events[1][:state])

    Timecop.travel(1.1) do
      # Acquiring the resource successfully generates a transition to half_open, then closed.
      resource.acquire { nil }
      assert_equal(4, events.length)
      assert_equal(name, events[2][:name])
      assert_equal(:half_open, events[2][:state])
      assert_equal(name, events[3][:name])
      assert_equal(:closed, events[3][:state])
    end
  ensure
    Semian.unsubscribe(:test_notify_state_transition)
  end
end
