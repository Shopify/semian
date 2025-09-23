# frozen_string_literal: true

require "test_helper"
require "timeout"

class TestPIDCircuitBreaker < Minitest::Test
  include CircuitBreakerHelper

  def setup
    @strio = StringIO.new
    Semian.logger = Logger.new(@strio)
  end

  def test_initialization_with_default_parameters
    circuit = Semian::PIDCircuitBreaker.new(
      :test_circuit,
      exceptions: [StandardError],
      error_timeout: 1,
      implementation: ::Semian::Simple,
    )

    assert_equal(:test_circuit, circuit.name)
    assert(circuit.closed?) # No rejection initially
    refute_predicate(circuit, :open?)
    refute_predicate(circuit, :partially_open?)
    assert_equal(0.0, circuit.current_error_rate)
    assert_equal(0.0, circuit.rejection_rate)
  end

  def test_initialization_with_custom_pid_parameters
    circuit = Semian::PIDCircuitBreaker.new(
      :test_circuit,
      exceptions: [StandardError],
      error_timeout: 1,
      implementation: ::Semian::Simple,
      pid_kp: 2.0,
      pid_ki: 0.5,
      pid_kd: 0.1,
      error_rate_setpoint: 0.1,
      max_rejection_rate: 0.8,
      sample_window_size: 50,
      min_requests: 5,
      ping_interval: 2.0,
      ping_weight: 0.5,
    )

    assert_equal(:test_circuit, circuit.name)
    assert_equal(0.1, circuit.error_rate_setpoint)
  end

  def test_partial_opening_based_on_p_value
    circuit = Semian::PIDCircuitBreaker.new(
      :test_circuit,
      exceptions: [StandardError],
      error_timeout: 1,
      implementation: ::Semian::Simple,
      pid_kp: 1.0,
      error_rate_setpoint: 0.1, # 10% error rate target
      min_requests: 5,
      max_rejection_rate: 0.95,
    )

    # Generate 50% error rate (well above setpoint)
    5.times { trigger_error!(circuit, StandardError) }
    5.times { trigger_success!(circuit) }

    # Error = 0.5 - 0.1 = 0.4
    # P term = 1.0 * 0.4 = 0.4
    # Rejection rate should be around 40%
    assert_in_delta(0.4, circuit.p_value, 0.1)

    # Should be partially open (not fully closed or open)
    assert(circuit.partially_open?)
    refute_predicate(circuit, :closed?)
    refute_predicate(circuit, :open?)
  end

  def test_rejection_probability
    circuit = Semian::PIDCircuitBreaker.new(
      :test_circuit,
      exceptions: [StandardError],
      error_timeout: 1,
      implementation: ::Semian::Simple,
      pid_kp: 10.0,
      error_rate_setpoint: 0.05,
      min_requests: 5,
    )

    # Generate high error rate to increase rejection rate
    10.times { trigger_error!(circuit, StandardError) }

    # With 100% errors and high kp, rejection rate should be high
    # Test that some requests get rejected
    rejections = 0
    attempts = 100

    attempts.times do
      circuit.acquire { true }
    rescue Semian::OpenCircuitError
      rejections += 1
    end

    # Should have some rejections but not all (partial opening)
    assert_operator(rejections, :>, 0, "Should have some rejections")
    assert_operator(rejections, :<, attempts, "Should not reject all requests")
  end

  def test_ping_functionality
    ping_results = []
    ping_called = false

    circuit = Semian::PIDCircuitBreaker.new(
      :test_circuit,
      exceptions: [StandardError],
      error_timeout: 1,
      implementation: ::Semian::Simple,
      pid_kp: 1.0,
      error_rate_setpoint: 0.05,
      min_requests: 3,
      ping_interval: 0.1, # Fast pings for testing
      ping_timeout: 0.5,
      ping_weight: 0.5,
    )

    # Configure ping
    circuit.configure_ping do
      ping_called = true
      result = ping_results.shift || true
      result
    end

    # Set up ping results
    ping_results = [true, true, false, false, true]

    # Wait for pings to execute
    sleep(0.6)

    assert(ping_called, "Ping should have been called")

    # Ping success rate should reflect the results
    # Note: exact rate depends on timing, but should be between 0 and 1
    assert_operator(circuit.ping_success_rate, :>=, 0.0)
    assert_operator(circuit.ping_success_rate, :<=, 1.0)
  end

  def test_ping_affects_rejection_rate
    circuit = Semian::PIDCircuitBreaker.new(
      :test_circuit,
      exceptions: [StandardError],
      error_timeout: 1,
      implementation: ::Semian::Simple,
      pid_kp: 1.0,
      error_rate_setpoint: 0.1,
      min_requests: 5,
      ping_weight: 0.5, # High weight for ping influence
      ping_interval: 0.1,
    )

    # Generate moderate error rate
    3.times { trigger_error!(circuit, StandardError) }
    7.times { trigger_success!(circuit) }

    initial_rejection = circuit.rejection_rate

    # Configure failing pings
    circuit.configure_ping { false }

    # Wait for pings
    sleep(0.3)

    # Rejection rate should increase with failing pings
    # (ping success low but we're rejecting, so P term increases)
    failing_ping_rejection = circuit.rejection_rate

    # Now configure successful pings
    circuit.configure_ping { true }
    sleep(0.3)

    successful_ping_rejection = circuit.rejection_rate

    # With successful pings and moderate errors, rejection should stabilize or decrease
    assert_operator(
      successful_ping_rejection, :<=, failing_ping_rejection, "Successful pings should reduce rejection rate"
    )
  end

  def test_max_rejection_rate
    circuit = Semian::PIDCircuitBreaker.new(
      :test_circuit,
      exceptions: [StandardError],
      error_timeout: 1,
      implementation: ::Semian::Simple,
      pid_kp: 100.0, # Very high gain
      error_rate_setpoint: 0.01,
      min_requests: 5,
      max_rejection_rate: 0.75, # Cap at 75%
    )

    # Generate 100% errors with very high gain
    10.times { trigger_error!(circuit, StandardError) }

    # Despite high P value, rejection rate should be capped
    assert_operator(circuit.rejection_rate, :<=, 0.75)

    # Test actual rejection behavior
    rejections = 0
    attempts = 100

    attempts.times do
      circuit.acquire { true }
    rescue Semian::OpenCircuitError
      rejections += 1
    end

    # Should reject roughly 75% or less
    assert_operator(rejections, :<=, 85, "Should respect max rejection rate (allowing for randomness)")
  end

  def test_no_traditional_state_transitions
    circuit = Semian::PIDCircuitBreaker.new(
      :test_circuit,
      exceptions: [StandardError],
      error_timeout: 1,
      implementation: ::Semian::Simple,
      pid_kp: 1.0,
      min_requests: 3,
    )

    # Half-open always returns false in new implementation
    refute_predicate(circuit, :half_open?)
    refute_predicate(circuit, :transition_to_half_open?)

    # Generate errors
    5.times { trigger_error!(circuit, StandardError) }

    # Still no half-open state
    refute_predicate(circuit, :half_open?)

    # Circuit is either closed, partially open, or effectively open
    # based on rejection rate
    assert(circuit.closed? || circuit.partially_open? || circuit.open?)
  end

  def test_smooth_rejection_rate_changes
    circuit = Semian::PIDCircuitBreaker.new(
      :test_circuit,
      exceptions: [StandardError],
      error_timeout: 1,
      implementation: ::Semian::Simple,
      pid_kp: 2.0,
      error_rate_setpoint: 0.05,
      min_requests: 5,
    )

    rates = []

    # Generate changing error patterns
    5.times { trigger_success!(circuit) }
    rates << circuit.rejection_rate

    2.times { trigger_error!(circuit, StandardError) }
    rates << circuit.rejection_rate

    3.times { trigger_error!(circuit, StandardError) }
    rates << circuit.rejection_rate

    5.times { trigger_success!(circuit) }
    rates << circuit.rejection_rate

    # Rates should change gradually, not jump dramatically
    rates.each_cons(2) do |prev, curr|
      change = (curr - prev).abs
      # Allow for up to 50% change per step (smoothing should prevent larger jumps)
      assert_operator(change, :<, 0.5, "Rejection rate should change smoothly")
    end
  end

  def test_reset_clears_state
    circuit = Semian::PIDCircuitBreaker.new(
      :test_circuit,
      exceptions: [StandardError],
      error_timeout: 1,
      implementation: ::Semian::Simple,
      pid_kp: 10.0,
      error_rate_setpoint: 0.05,
      min_requests: 3,
    )

    # Generate errors to increase rejection rate
    5.times { trigger_error!(circuit, StandardError) }

    assert_operator(circuit.rejection_rate, :>, 0)

    # Reset should clear everything
    circuit.reset

    assert(circuit.closed?)
    assert_equal(0.0, circuit.current_error_rate)
    assert_equal(0.0, circuit.rejection_rate)
    assert_equal(0.0, circuit.p_value)
  end

  def test_in_use_when_requests_present
    circuit = Semian::PIDCircuitBreaker.new(
      :test_circuit,
      exceptions: [StandardError],
      error_timeout: 1,
      implementation: ::Semian::Simple,
    )

    refute_predicate(circuit, :in_use?)

    trigger_success!(circuit)

    assert(circuit.in_use?)

    circuit.reset

    refute_predicate(circuit, :in_use?)
  end

  def test_thread_safe_implementation
    circuit = Semian::PIDCircuitBreaker.new(
      :test_circuit,
      exceptions: [StandardError],
      error_timeout: 1,
      implementation: ::Semian::ThreadSafe,
      pid_kp: 1.0,
      error_rate_setpoint: 0.1,
      min_requests: 10,
    )

    threads = []
    errors = 0
    successes = 0
    rejections = 0
    mutex = Mutex.new

    # Simulate concurrent requests
    20.times do |i|
      threads << Thread.new do
        circuit.acquire do
          if i % 3 == 0
            raise StandardError, "Test error"
          else
            mutex.synchronize { successes += 1 }
          end
        end
      rescue StandardError => e
        if e.message.include?("rejected by PID")
          mutex.synchronize { rejections += 1 }
        else
          mutex.synchronize { errors += 1 }
        end
      end
    end

    threads.each(&:join)

    # Should have processed all requests (success + errors + rejections = 20)
    total = successes + errors + rejections

    assert_equal(20, total)

    # Should have some errors from the raised exceptions
    assert_operator(errors, :>, 0)
  end

  def test_ping_timeout_handling
    slow_ping_called = false

    circuit = Semian::PIDCircuitBreaker.new(
      :test_circuit,
      exceptions: [StandardError],
      error_timeout: 1,
      implementation: ::Semian::Simple,
      ping_interval: 0.1,
      ping_timeout: 0.05, # Very short timeout
    )

    # Configure slow ping that exceeds timeout
    circuit.configure_ping do
      slow_ping_called = true
      sleep(0.1) # Longer than timeout
      true
    end

    sleep(0.2) # Wait for ping

    assert(slow_ping_called)
    # Ping should be recorded as failure due to timeout
    assert_operator(circuit.ping_success_rate, :<, 1.0)
  end

  def test_errors_not_marking_circuits_are_ignored
    circuit = Semian::PIDCircuitBreaker.new(
      :test_circuit,
      exceptions: [StandardError],
      error_timeout: 1,
      implementation: ::Semian::Simple,
      pid_kp: 10.0,
      min_requests: 3,
    )

    error = StandardError.new("Test")
    def error.marks_semian_circuits?
      false
    end

    # These errors shouldn't affect the circuit
    3.times do
      assert_raises(StandardError) do
        circuit.acquire { raise error }
      end
    end

    # Circuit should still be closed
    assert(circuit.closed?)
    assert_equal(0.0, circuit.current_error_rate)
    assert_equal(0.0, circuit.rejection_rate)
  end

  def test_request_allowed_based_on_rejection
    circuit = Semian::PIDCircuitBreaker.new(
      :test_circuit,
      exceptions: [StandardError],
      error_timeout: 1,
      implementation: ::Semian::Simple,
      pid_kp: 1.0,
      min_requests: 5,
    )

    # Initially all requests allowed
    assert(circuit.request_allowed?)

    # Generate errors to increase rejection rate
    10.times { trigger_error!(circuit, StandardError) }

    # request_allowed? is probabilistic based on rejection rate
    # Test multiple times to see both outcomes
    outcomes = []
    100.times do
      outcomes << circuit.request_allowed?
    end

    # Should have some true and some false
    assert(outcomes.include?(true) || circuit.rejection_rate >= 0.99)
    assert(outcomes.include?(false) || circuit.rejection_rate <= 0.01)
  end

  private

  def trigger_error!(circuit, exception_class)
    circuit.acquire { raise exception_class.new("Test error") }
  rescue exception_class, Semian::OpenCircuitError
    # Expected - error or rejection
  end

  def trigger_success!(circuit)
    circuit.acquire { true }
  rescue Semian::OpenCircuitError
    # Can be rejected even on success attempt
  end

  def assert_circuit_closed(circuit)
    assert(circuit.closed?, "Expected circuit to be closed")
    refute_predicate(circuit, :open?, "Expected circuit not to be open")
    refute_predicate(circuit, :partially_open?, "Expected circuit not to be partially open")
  end
end
