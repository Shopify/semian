# frozen_string_literal: true

require "test_helper"

class TestSemian < Minitest::Test
  def setup
    destroy_all_semian_resources
  end

  def test_unsupported_acquire_yields
    acquired = false
    Semian.register(:testing, tickets: 1, error_threshold: 1, error_timeout: 2, success_threshold: 1)
    Semian[:testing].acquire { acquired = true }

    assert(acquired)
  end

  def test_register_with_circuit_breaker_missing_options
    exception = assert_raises(ArgumentError) do
      Semian.register(
        :testing,
        error_threshold: 2,
        error_timeout: 5,
        bulkhead: false,
      )
    end

    assert_equal("Missing required arguments for Semian: [:success_threshold]", exception.message)
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

    assert_equal(resource, Semian[:testing])
    assert_instance_of(Semian::ThreadSafe::State, resource.circuit_breaker.state)
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

    assert_equal(resource, Semian[:testing])
    assert_instance_of(Semian::Simple::State, resource.circuit_breaker.state)
  end

  def test_register_with_bulkhead_missing_options
    exception = assert_raises(ArgumentError) do
      Semian.register(
        :testing,
        circuit_breaker: false,
      )
    end

    assert_equal(
      "Semian configuration require either the :tickets or :quota parameter, you provided neither",
      exception.message,
    )
  end

  def test_register_with_exclusive_options
    exception = assert_raises(ArgumentError) do
      Semian.register(
        :testing,
        tickets: 42,
        quota: 42,
        circuit_breaker: false,
      )
    end

    assert_equal(
      "Semian configuration require either the :tickets or :quota parameter, you provided both",
      exception.message,
    )
  end

  def test_unsuported_constants
    assert(defined?(Semian::BaseError))
    assert(defined?(Semian::SyscallError))
    assert(defined?(Semian::TimeoutError))
    assert(defined?(Semian::InternalError))
    assert(defined?(Semian::Resource))
  end

  def test_disabled_via_env_var
    ENV["SEMIAN_SEMAPHORES_DISABLED"] = "1"

    refute_predicate(Semian, :semaphores_enabled?)
  ensure
    ENV.delete("SEMIAN_SEMAPHORES_DISABLED")
  end

  def test_disabled_via_semian_wide_env_var
    ENV["SEMIAN_DISABLED"] = "1"

    refute_predicate(Semian, :semaphores_enabled?)
  ensure
    ENV.delete("SEMIAN_DISABLED")
  end

  def test_disabled_both_bulkheading_and_circuit_breaker
    exception = assert_raises(ArgumentError) do
      Semian.register(
        :disabled_bulkhead_and_circuit_breaker,
        bulkhead: false,
        circuit_breaker: false,
      )
    end

    assert_equal(
      "Both bulkhead and circuitbreaker cannot be disabled.",
      exception.message,
    )
  end

  def test_disabled_bulkheading
    resource = Semian.register(
      :disabled_bulkhead,
      bulkhead: false,
      success_threshold: 1,
      error_threshold: 1,
      error_timeout: 1,
    )

    assert_nil(resource.bulkhead)
  end

  def test_disabled_bulkhead_via_env
    ENV["SEMIAN_BULKHEAD_DISABLED"] = "1"

    resource = Semian.register(
      :disabled_bulkhead_via_env,
      success_threshold: 1,
      error_threshold: 1,
      error_timeout: 1,
    )

    assert_nil(resource.bulkhead)
  ensure
    ENV.delete("SEMIAN_BULKHEAD_DISABLED")
  end

  def test_disabled_bulkhead_via_env_with_option_enabled
    ENV["SEMIAN_BULKHEAD_DISABLED"] = "1"

    resource = Semian.register(
      :disabled_bulkhead_via_env,
      bulkhead: true,
      tickets: 1,
      success_threshold: 1,
      error_threshold: 1,
      error_timeout: 1,
    )

    assert_nil(resource.bulkhead)
  ensure
    ENV.delete("SEMIAN_BULKHEAD_DISABLED")
  end

  def test_disabled_bulkhead_via_thread
    Semian.disable_bulkheads_for_thread(Thread.current) do
      resource = Semian.register(
        :disabled_bulkhead_via_env,
        bulkhead: true,
        tickets: 1,
        success_threshold: 1,
        error_threshold: 1,
        error_timeout: 1,
      )

      assert_nil(resource.bulkhead)
    end
  end

  def test_disabled_circuit_breaker
    resource = Semian.register(
      :disabled_circuit_breaker,
      tickets: 1,
      circuit_breaker: false,
    )

    assert_nil(resource.circuit_breaker)
  end

  def test_disabled_circuit_breaker_via_env
    ENV["SEMIAN_CIRCUIT_BREAKER_DISABLED"] = "1"

    resource = Semian.register(
      :disabled_circuit_breaker_via_env,
      tickets: 1,
    )

    assert_nil(resource.circuit_breaker)
  ensure
    ENV.delete("SEMIAN_CIRCUIT_BREAKER_DISABLED")
  end

  def test_disabled_circuit_breaker_via_semian_env
    ENV["SEMIAN_DISABLED"] = "1"

    resource = Semian.register(:disabled_semina_via_env)

    assert_nil(resource.circuit_breaker)
    assert_nil(resource.bulkhead)
  ensure
    ENV.delete("SEMIAN_DISABLED")
  end

  def test_enabled_circuit_breaker_by_options_but_disabled_by_env
    ENV["SEMIAN_CIRCUIT_BREAKER_DISABLED"] = "1"

    resource = Semian.register(
      :disabled_circuit_breaker_conflict,
      bulkhead: true,
      tickets: 1,
      circuit_breaker: true,
      success_threshold: 1,
      error_threshold: 1,
      error_timeout: 1,
    )

    assert_nil(resource.circuit_breaker)
  ensure
    ENV.delete("SEMIAN_CIRCUIT_BREAKER_DISABLED")
  end

  def test_register_with_quota
    resource = Semian.register(
      :testing_quota,
      bulkhead: true,
      quota: 0.5,
      circuit_breaker: false,
    )

    assert_equal(resource, Semian[:testing_quota])
  end

  def test_register_with_invalid_quota
    assert_raises(ArgumentError) do
      Semian.register(
        :testing_invalid_quota,
        bulkhead: true,
        quota: 1.5,
        circuit_breaker: false,
      )
    end
  end

  def test_register_with_tickets
    resource = Semian.register(
      :testing_tickets,
      bulkhead: true,
      tickets: 5,
      circuit_breaker: false,
    )

    assert_equal(resource, Semian[:testing_tickets])
    assert_equal(5, resource.bulkhead.tickets)
  end

  def test_register_with_invalid_tickets
    assert_raises(ArgumentError) do
      Semian.register(
        :testing_invalid_tickets,
        bulkhead: true,
        tickets: -1,
        circuit_breaker: false,
      )
    end
  end

  def test_register_with_resource_name
    resource = Semian.register(
      :testing_named_resource,
      bulkhead: true,
      tickets: 5,
      circuit_breaker: false,
    )

    assert_equal(resource, Semian[:testing_named_resource])
  end

  def test_register_with_duplicate_resource_name_error
    Semian.register(
      :duplicate_name,
      bulkhead: true,
      tickets: 5,
      circuit_breaker: false,
    )

    error = assert_raises(ArgumentError) do
      Semian.register(
        :duplicate_name,
        bulkhead: true,
        tickets: 5,
        circuit_breaker: false,
      )
    end
    assert_equal("Resource with name duplicate_name is already registered", error.message)
  end

  def test_disabled_circuit_breaker_via_env_with_invalid_config
    ENV["SEMIAN_CIRCUIT_BREAKER_DISABLED"] = "1"

    # Should still validate configuration even though circuit breaker will be disabled
    error = assert_raises(ArgumentError) do
      Semian.register(
        :testing_invalid_config,
        bulkhead: false,
        circuit_breaker: true,
      )
    end

    assert_equal("Both bulkhead and circuitbreaker cannot be disabled.", error.message)
  ensure
    ENV.delete("SEMIAN_CIRCUIT_BREAKER_DISABLED")
  end

  def test_bulkhead_with_valid_tickets
    resource = Semian.register(
      :testing_bulkhead_tickets,
      bulkhead: true,
      tickets: 10,
      circuit_breaker: false,
    )

    assert_equal(resource, Semian[:testing_bulkhead_tickets])
    assert_equal(10, resource.bulkhead.tickets)
    assert_nil(resource.circuit_breaker)
  end

  def test_bulkhead_with_valid_quota
    resource = Semian.register(
      :testing_bulkhead_quota,
      bulkhead: true,
      quota: 0.75,
      circuit_breaker: false,
    )

    assert_equal(resource, Semian[:testing_bulkhead_quota])
  end

  def test_bulkhead_with_invalid_quota_above_one
    error = assert_raises(ArgumentError) do
      Semian.register(
        :testing_bulkhead_invalid_quota_high,
        bulkhead: true,
        quota: 1.5,
        circuit_breaker: false,
      )
    end

    assert_equal("quota must be a decimal between 0 and 1", error.message)
  end

  def test_bulkhead_with_invalid_quota_zero
    error = assert_raises(ArgumentError) do
      Semian.register(
        :testing_bulkhead_invalid_quota_zero,
        bulkhead: true,
        quota: 0,
        circuit_breaker: false,
      )
    end

    assert_equal("quota must be a decimal between 0 and 1", error.message)
  end

  def test_bulkhead_with_invalid_quota_negative
    error = assert_raises(ArgumentError) do
      Semian.register(
        :testing_bulkhead_invalid_quota_negative,
        bulkhead: true,
        quota: -0.5,
        circuit_breaker: false,
      )
    end

    assert_equal("quota must be a decimal between 0 and 1", error.message)
  end

  def test_bulkhead_with_invalid_tickets_negative
    error = assert_raises(ArgumentError) do
      Semian.register(
        :testing_bulkhead_invalid_tickets_negative,
        bulkhead: true,
        tickets: -5,
        circuit_breaker: false,
      )
    end

    assert_equal("ticket count must be a non-negative integer and less than #{Semian::MAX_TICKETS}", error.message)
  end

  def test_bulkhead_with_invalid_tickets_above_max
    error = assert_raises(ArgumentError) do
      Semian.register(
        :testing_bulkhead_invalid_tickets_max,
        bulkhead: true,
        tickets: Semian::MAX_TICKETS + 1,
        circuit_breaker: false,
      )
    end

    assert_equal("ticket count must be a non-negative integer and less than #{Semian::MAX_TICKETS}", error.message)
  end

  def test_bulkhead_with_both_circuit_breaker_and_bulkhead_disabled
    error = assert_raises(ArgumentError) do
      Semian.register(
        :testing_both_disabled,
        bulkhead: false,
        circuit_breaker: false,
      )
    end

    assert_equal("Both bulkhead and circuitbreaker cannot be disabled.", error.message)
  end
end
