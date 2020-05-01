require 'test_helper'

class TestSemian < Minitest::Test
  def setup
    Semian.destroy(:testing)
  rescue
    nil
  end

  def test_unsupported_acquire_yields
    acquired = false
    Semian.register :testing, tickets: 1, error_threshold: 1, error_timeout: 2, success_threshold: 1
    Semian[:testing].acquire { acquired = true }
    assert acquired
  end

  def test_register_with_circuit_breaker_missing_options
    exception = assert_raises ArgumentError do
      Semian.register(
        :testing,
        error_threshold: 2,
        error_timeout: 5,
        bulkhead: false,
      )
    end
    assert_equal \
      exception.message,
      "Missing required arguments for Semian: [:success_threshold]"
  end

  def test_register_with_thread_safety_enabled
    resource = Semian.register(
      :testing,
      success_threshold: 1,
      error_threshold: 2,
      error_timeout: 5,
      circuit_breaker: true,
      bulkhead: false,
      thread_safety_disabled: false,
    )

    assert resource, Semian[:testing]
    assert resource.circuit_breaker.state.instance_of?(Semian::ThreadSafe::State)
  end

  def test_register_with_thread_safety_disabled
    resource = Semian.register(
      :testing,
      success_threshold: 1,
      error_threshold: 2,
      error_timeout: 5,
      circuit_breaker: true,
      bulkhead: false,
      thread_safety_disabled: true,
    )

    assert resource, Semian[:testing]
    assert resource.circuit_breaker.state.instance_of?(Semian::Simple::State)
  end

  def test_register_with_bulkhead_missing_options
    exception = assert_raises ArgumentError do
      Semian.register(
        :testing,
        circuit_breaker: false,
      )
    end
    assert_equal exception.message, "Must pass exactly one of ticket or quota"
  end

  def test_register_with_error_rate_circuitbreaker
    resource = Semian.register(
        :testing_error_rate,
        circuit_breaker_type: :error_rate,
        success_threshold: 1,
        error_percent_threshold: 0.2,
        minimum_request_volume: 1,
        time_window: 10,
        error_timeout: 5,
        circuit_breaker: true,
        bulkhead: false,
        thread_safety_disabled: false,
        )

    assert resource, Semian[:testing_error_rate]
    assert resource.circuit_breaker.state.instance_of?(Semian::ThreadSafe::State)
    assert resource.circuit_breaker.instance_of?(Semian::ErrorRateCircuitBreaker)
  end

  def test_unsuported_constants
    assert defined?(Semian::BaseError)
    assert defined?(Semian::SyscallError)
    assert defined?(Semian::TimeoutError)
    assert defined?(Semian::InternalError)
    assert defined?(Semian::Resource)
  end

  def test_disabled_via_env_var
    ENV['SEMIAN_SEMAPHORES_DISABLED'] = '1'

    refute Semian.semaphores_enabled?
  ensure
    ENV.delete('SEMIAN_SEMAPHORES_DISABLED')
  end

  def test_disabled_via_semian_wide_env_var
    ENV['SEMIAN_DISABLED'] = '1'

    refute Semian.semaphores_enabled?
  ensure
    ENV.delete('SEMIAN_DISABLED')
  end
end
