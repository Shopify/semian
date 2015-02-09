require 'test/unit'
require 'semian'
require 'timecop'

class TestCircuitBreaker < Test::Unit::TestCase
  SomeError = Class.new(StandardError)

  def setup
    Semian[:testing].destroy rescue nil
    Semian.register(:testing, tickets: 1, exceptions: [SomeError], error_threshold: 2, error_timeout: 5)
    @resource = Semian[:testing]
  end

  def test_with_fallback_value_returns_the_value
    result = @resource.with_fallback(42) do
      raise SomeError
    end
    assert_equal 42, result
  end

  def test_with_fallback_block_call_the_block
    result = @resource.with_fallback(-> { 42 }) do
      raise SomeError
    end
    assert_equal 42, result
  end

  def test_unknown_exceptions_are_not_rescued
    assert_raises RuntimeError do
      @resource.with_fallback(42) do
        raise RuntimeError
      end
    end
  end

  def test_all_semian_exceptions_are_rescued
    result = @resource.with_fallback(42) do
      raise Semian::BaseError
    end
    assert_equal 42, result
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

  private

  def open_circuit!
    2.times { trigger_error! }
  end

  def half_open_cicuit!
    Timecop.travel(Time.now - 10) do
      open_circuit!
    end
  end

  def trigger_error!
    @resource.with_fallback(42) { raise SomeError }
  end

  def assert_circuit_closed
    block_called = false
    @resource.with_fallback(42) { block_called = true }
    assert block_called, 'Expected the circuit to be closed, but it was open'
  end

  def assert_circuit_opened
    block_called = false
    @resource.with_fallback(42) { block_called = true }
    refute block_called, 'Expected the circuit to be open, but it was closed'
  end
end
