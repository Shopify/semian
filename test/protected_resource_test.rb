require 'test_helper'

class TestProtectedResource < Minitest::Test
  include CircuitBreakerHelper
  include ResourceHelper
  include BackgroundHelper

  def setup
    Semian.destroy(:testing)
  rescue
    nil
  end

  def teardown
    destroy_resources
    super
  end

  def test_get_name_without_bulkhead
    Semian.register(
      :testing,
      exceptions: [SomeError],
      error_threshold: 2,
      error_timeout: 5,
      success_threshold: 1,
      bulkhead: false,
    )

    refute_nil Semian.resources[:testing].name
  end

  def test_get_name_without_bulkhead_or_circuit_breaker
    Semian.register(
      :testing,
      exceptions: [SomeError],
      error_threshold: 2,
      error_timeout: 5,
      success_threshold: 1,
      bulkhead: false,
      circuit_breaker: false,
    )

    assert_nil Semian.resources[:testing].name
  end

  def test_acquire_without_bulkhead
    Semian.register(
      :testing,
      exceptions: [SomeError],
      error_threshold: 2,
      error_timeout: 5,
      success_threshold: 1,
      bulkhead: false,
    )

    10.times do
      background do
        block_called = false
        @resource = Semian[:testing]
        @resource.acquire { block_called = true }
        assert_equal true, block_called
        assert_instance_of Semian::CircuitBreaker, @resource.circuit_breaker
        assert_nil @resource.bulkhead
      end
    end

    yield_to_background
  end

  def test_acquire_bulkhead_without_circuit_breaker
    Semian.register(
      :testing,
      tickets: 2,
      circuit_breaker: false,
    )
    acquired = false

    @resource = Semian[:testing]
    @resource.acquire do
      acquired = true
      assert_equal 1, @resource.count
      assert_equal 2, @resource.tickets
    end

    assert acquired
    assert_nil @resource.circuit_breaker
  end

  def test_acquire_bulkhead_with_circuit_breaker
    Semian.register(
      :testing,
      tickets: 2,
      exceptions: [SomeError],
      error_threshold: 2,
      error_timeout: 5,
      success_threshold: 1,
    )

    acquired = false

    @resource = Semian[:testing]
    @resource.acquire do
      acquired = true
      assert_equal 1, @resource.count
      assert_equal 2, @resource.tickets
      half_open_cicuit!(@resource)
      assert_circuit_closed(@resource)
    end

    assert acquired
  end
end
