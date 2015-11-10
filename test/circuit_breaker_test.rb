require 'test_helper'

class TestCircuitBreaker < MiniTest::Unit::TestCase
  SomeError = Class.new(StandardError)

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

  private

  def open_circuit!(resource = @resource)
    2.times { trigger_error!(resource) }
  end

  def half_open_cicuit!(resource = @resource)
    Timecop.travel(Time.now - 10) do
      open_circuit!(resource)
    end
  end

  def trigger_error!(resource = @resource)
    resource.acquire { raise SomeError }
  rescue SomeError
  end

  def assert_circuit_closed(resource = @resource)
    block_called = false
    resource.acquire { block_called = true }
    assert block_called, 'Expected the circuit to be closed, but it was open'
  end

  def assert_circuit_opened(resource = @resource)
    open = false
    begin
      resource.acquire {}
    rescue Semian::OpenCircuitError
      open = true
    end
    assert open, 'Expected the circuit to be open, but it was closed'
  end
end
