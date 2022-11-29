# frozen_string_literal: true

require "test_helper"
require "securerandom"

class TestProtectedResource < Minitest::Test
  include CircuitBreakerHelper
  include ResourceHelper
  include BackgroundHelper
  include TimeHelper

  def setup
    Semian.destroy(:testing)
  rescue
    nil
  end

  def teardown
    destroy_resources
    super
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

        assert(block_called)
        assert_instance_of(Semian::CircuitBreaker, @resource.circuit_breaker)
        assert_nil(@resource.bulkhead)
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

      assert_equal(1, @resource.count)
      assert_equal(2, @resource.tickets)
    end

    assert(acquired)
    assert_nil(@resource.circuit_breaker)
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

      assert_equal(1, @resource.count)
      assert_equal(2, @resource.tickets)
      half_open_cicuit!(@resource)

      assert_circuit_closed(@resource)
    end

    assert(acquired)
  end

  def test_register_without_any_resource_fails
    assert_raises(ArgumentError) do
      Semian.register(
        :testing,
        circuit_breaker: false,
      )
    end
  end

  def test_responds_to_name_when_bulkhead_or_circuit_breaker_disabled
    Semian.register(
      :no_bulkhead,
      error_threshold: 2,
      error_timeout: 5,
      success_threshold: 1,
      bulkhead: false,
      circuit_breaker: true,
    )

    Semian.register(
      :no_circuit_breaker,
      tickets: 2,
      bulkhead: true,
      circuit_breaker: false,
    )

    assert_equal(:no_bulkhead, Semian[:no_bulkhead].name)
    assert_equal(:no_circuit_breaker, Semian[:no_circuit_breaker].name)
  end

  def test_gracefully_fails_when_unable_to_decrement_ticket_count
    reader, writer = IO.pipe
    my_exception = Class.new(StandardError)
    name = :"contended_resource_#{SecureRandom.hex}"
    options = {
      bulkhead: true,
      circuit_breaker: false,
    }

    workers = [1, 2].map do
      Process.fork do
        Semian.register(name, tickets: 2, **options).acquire do
          Signal.trap("INT") do
            raise(my_exception)
          end
          begin
            writer.write("\n")
            sleep
          rescue my_exception
          end
        end
      end
    end

    reader.read(2)

    assert_raises(Semian::TimeoutError) do
      Semian.register(name, tickets: 1, **options)
    end

    Process.kill("INT", workers.shift)

    Semian.register(name, tickets: 1, **options)
  ensure
    workers&.each do |pid|
      Process.kill("INT", pid)
    end
  end
end
