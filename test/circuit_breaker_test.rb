require 'test_helper'

class TestCircuitBreaker < Minitest::Test
  include CircuitBreakerHelper

  def setup
    begin
      Semian.destroy(:testing)
    rescue
      nil
    end
    Semian.register(:testing, tickets: 1, exceptions: [SomeError], error_threshold: 2, error_timeout: 5, success_threshold: 1)
    @resource = Semian[:testing]
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
  end

  def test_once_success_threshold_is_reached_only_error_threshold_will_open_the_circuit_again
    half_open_cicuit!
    assert_circuit_closed
    trigger_error!
    assert_circuit_closed
    trigger_error!
    assert_circuit_opened
  end

  def test_reset_allow_to_close_the_circuit_and_forget_errors
    open_circuit!
    @resource.reset
    assert_circuit_closed
  end

  def test_errors_more_than_duration_apart_doesnt_open_circuit
    Timecop.travel(Time.now - 6) do
      trigger_error!
      assert_circuit_closed
    end

    trigger_error!
    assert_circuit_closed
  end

  def test_sparse_errors_dont_open_circuit
    resource = Semian.register(:three, tickets: 1, exceptions: [SomeError], error_threshold: 3, error_timeout: 5, success_threshold: 1)

    Timecop.travel(-6) do
      trigger_error!(resource)
      assert_circuit_closed(resource)
    end

    Timecop.travel(-1) do
      trigger_error!(resource)
      assert_circuit_closed(resource)
    end

    trigger_error!(resource)
    assert_circuit_closed(resource)
  ensure
    Semian.destroy(:three)
  end

  def test_request_allowed_query_doesnt_trigger_transitions
    Timecop.travel(Time.now - 6) do
      open_circuit!

      refute_predicate @resource, :request_allowed?
      assert_predicate @resource, :open?
    end

    assert_predicate @resource, :request_allowed?
    assert_predicate @resource, :open?
  end

  def test_open_close_open_cycle
    resource = Semian.register(:open_close, tickets: 1, exceptions: [SomeError], error_threshold: 2, error_timeout: 5, success_threshold: 2)

    half_open_future_travel = -> { Time.now + resource.circuit_breaker.error_timeout + 1 }

    open_circuit!(resource)
    assert_circuit_opened(resource)

    Timecop.travel(half_open_future_travel.call) do
      assert_circuit_closed(resource)

      assert resource.half_open?
      assert_circuit_closed(resource)

      assert resource.closed?

      open_circuit!(resource)
      assert_circuit_opened(resource)

      Timecop.travel(half_open_future_travel.call) do
        assert_circuit_closed(resource)

        assert resource.half_open?
        assert_circuit_closed(resource)

        assert resource.closed?
      end
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
    Semian.register(:resource_timeout, tickets: 1, exceptions: [SomeError],
                                       error_threshold: 2, error_timeout: 5, success_threshold: 1,
                                       half_open_resource_timeout: 0.123)
    resource = Semian[:resource_timeout]

    half_open_cicuit!(resource)

    raw_resource = RawResource.new

    triggered = false
    resource.acquire(resource: raw_resource) do
      triggered = true
      assert_equal 0.123, raw_resource.timeout
    end

    assert triggered
    assert_equal 2, raw_resource.timeout
  end

  def test_doesnt_change_resource_timeout_when_closed
    Semian.register(:resource_timeout, tickets: 1, exceptions: [SomeError],
                                       error_threshold: 2, error_timeout: 5, success_threshold: 1,
                                       half_open_resource_timeout: 0.123)
    resource = Semian[:resource_timeout]

    raw_resource = RawResource.new

    triggered = false
    resource.acquire(resource: raw_resource) do
      triggered = true
      assert_equal 2, raw_resource.timeout
    end

    assert triggered
    assert_equal 2, raw_resource.timeout
  end

  def test_doesnt_blow_up_when_configured_half_open_timeout_but_adapter_doesnt_support
    Semian.register(:resource_timeout, tickets: 1, exceptions: [SomeError],
                                       error_threshold: 2, error_timeout: 5, success_threshold: 1,
                                       half_open_resource_timeout: 0.123)
    resource = Semian[:resource_timeout]

    raw_resource = Object.new

    triggered = false
    resource.acquire(resource: raw_resource) do
      triggered = true
    end

    assert triggered
  end
end
