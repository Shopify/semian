# frozen_string_literal: true

require "test_helper"
require "semian/pid_controller"

class TestPIDController < Minitest::Test
  include TimeHelper

  def setup
    Process.stubs(:clock_gettime).with(Process::CLOCK_MONOTONIC).returns(1000)
    @controller = Semian::PIDController.new(
      name: "test_controller",
      kp: 1.0,
      ki: 0.1,
      kd: 0.01,
      window_size: 5,
      initial_history_duration: 100,
      initial_error_rate: 0.01,
    )
  end

  def teardown
    @controller.reset
    Process.unstub(:clock_gettime)
  end

  def test_initialization
    assert_equal("test_controller", @controller.name)
    assert_equal(0.0, @controller.rejection_rate)

    metrics = @controller.metrics
    # P = (error_rate - ideal_error_rate) - (rejection_rate - ping_failure_rate)
    # P = (0.0 - 0.01) - (0.0 - 0.0) = -0.01 - 0 = -0.01
    assert_equal(
      {
        rejection_rate: 0.0,
        error_rate: 0.0,
        ping_failure_rate: 0.0,
        ideal_error_rate: 0.01, # Default when no history
        health_metric: -0.01,
        integral: 0.0,
        previous_error: 0.0,
        current_window_requests: { success: 0, error: 0, rejected: 0 },
        current_window_pings: { success: 0, failure: 0 },
      },
      metrics,
    )
  end

  def test_record_request_success
    @controller.record_request(:success)
    @controller.record_request(:success)
    @controller.record_request(:success)

    # Metrics still 0 until window completes
    metrics = @controller.metrics

    assert_equal(0.0, metrics[:error_rate])
    assert_equal({ success: 3, error: 0, rejected: 0 }, metrics[:current_window_requests])

    # Move time forward past window size and update
    time_travel(6.0) do
      @controller.update
      metrics = @controller.metrics

      assert_equal(0.0, metrics[:error_rate])
    end
  end

  def test_record_request_errors
    @controller.record_request(:error)
    @controller.record_request(:success)
    @controller.record_request(:error)

    # Metrics still 0 until window completes
    metrics = @controller.metrics

    assert_equal(0.0, metrics[:error_rate])
    assert_equal({ success: 1, error: 2, rejected: 0 }, metrics[:current_window_requests])

    # Move time forward past window size and update
    time_travel(6.0) do
      @controller.update
      metrics = @controller.metrics

      assert_in_delta(0.666, metrics[:error_rate], 0.01)
    end
  end

  def test_ping_failure_rate_calculation
    @controller.record_ping(:success)
    @controller.record_ping(:failure)
    @controller.record_ping(:success)
    @controller.record_ping(:failure)

    # Metrics still 0 until window completes
    metrics = @controller.metrics

    assert_equal(0.0, metrics[:ping_failure_rate])
    assert_equal({ success: 2, failure: 2 }, metrics[:current_window_pings])

    # Move time forward past window size and update
    time_travel(6.0) do
      @controller.update
      metrics = @controller.metrics

      assert_equal(0.5, metrics[:ping_failure_rate])
    end
  end

  def test_health_metric_calculation
    # Record some errors
    5.times { @controller.record_request(:error) }
    5.times { @controller.record_request(:success) }

    # Record some ping failures
    3.times { @controller.record_ping(:failure) }
    2.times { @controller.record_ping(:success) }

    # Move time forward past window size and update
    time_travel(6.0) do
      @controller.update
      metrics = @controller.metrics
      error_rate = metrics[:error_rate] # 0.5
      ping_failure_rate = metrics[:ping_failure_rate] # 0.6

      # P = (error_rate - ideal_error_rate) - (rejection_rate - ping_failure_rate)
      # P = (0.5 - 0.01) - (0.0 - 0.6) = 0.49 - (-0.6) = 0.49 + 0.6 = 1.09
      health_metric = @controller.calculate_health_metric(error_rate, ping_failure_rate)

      assert_in_delta(1.09, health_metric, 0.01)
    end
  end

  def test_rejection_rate_increases_with_errors
    # Simulate high error rate
    10.times { @controller.record_request(:error) }

    initial_rejection_rate = @controller.rejection_rate

    # Advance time to ensure dt > 0 for PID calculations
    time_travel(1.0) do
      @controller.update
    end

    # Rejection rate should increase
    assert_operator(@controller.rejection_rate, :>, initial_rejection_rate)
  end

  def test_rejection_rate_decreases_with_successful_pings
    # Set up initial rejection rate
    10.times { @controller.record_request(:error) }

    time_travel(1.0) do
      @controller.update

      initial_rejection = @controller.rejection_rate

      # Now simulate successful pings and lower error rate
      10.times { @controller.record_request(:success) }
      5.times { @controller.record_ping(:success) }

      time_travel(1.0) do
        @controller.update

        assert_operator(@controller.rejection_rate, :<, initial_rejection)
      end
    end
  end

  def test_rejection_rate_clamped_between_0_and_1
    # Try to drive rejection rate very high
    100.times { @controller.record_request(:error) }
    100.times { @controller.record_ping(:failure) }

    time_travel(1.0) do
      @controller.update
    end

    assert_operator(@controller.rejection_rate, :<=, 1.0)
    assert_operator(@controller.rejection_rate, :>=, 0.0)
  end

  def test_should_reject_probability
    # Set rejection rate to 0.5 by manipulating the controller state
    @controller.instance_variable_set(:@rejection_rate, 0.5)

    # Mock rand to return deterministic values
    sequence = [0.3, 0.7, 0.4, 0.6, 0.2, 0.8, 0.5, 0.1, 0.9, 0.45]
    index = 0

    @controller.stub(:rand, -> {
      val = sequence[index % sequence.length]
      index += 1
      val
    }) do
      rejections = 0
      10.times do
        rejections += 1 if @controller.should_reject?
      end

      # With rejection_rate = 0.5, values < 0.5 should be rejected
      # From sequence: 0.3, 0.4, 0.2, 0.1, 0.45 = 5 rejections
      assert_equal(5, rejections)
    end
  end

  def test_reset_clears_all_state
    # Add some data
    @controller.record_request(:error)
    @controller.record_ping(:failure)

    time_travel(1.0) do
      @controller.update
    end

    # Reset
    @controller.reset

    assert_equal(0.0, @controller.rejection_rate)
    metrics = @controller.metrics

    assert_equal(0.0, metrics[:error_rate])
    assert_equal(0.0, metrics[:ping_failure_rate])
  end

  def test_ideal_error_rate_calculation_p90
    controller = Semian::PIDController.new(
      name: "test_p90",
      window_size: 1,
      initial_history_duration: 100,
      initial_error_rate: 0.01,
    )

    5.times do
      controller.send(:store_error_rate, 0.05)
    end
    4.times do
      controller.send(:store_error_rate, 0.09)
    end
    controller.send(:store_error_rate, 0.99)

    ideal_rate = controller.send(:calculate_ideal_error_rate)

    assert_equal(0.09, ideal_rate)
  end

  def test_ideal_error_rate_cap
    controller = Semian::PIDController.new(
      name: "test_cap",
      window_size: 1,
      initial_history_duration: 100,
      initial_error_rate: 0.01,
    )

    # Simulate high error rates
    10.times do
      controller.send(:store_error_rate, 0.5) # 50% error rate
    end

    ideal_rate = controller.send(:calculate_ideal_error_rate)

    # Should be capped at 10%
    assert_equal(0.1, ideal_rate)
  end

  def test_discrete_window_behavior
    # Record data in first window
    @controller.record_request(:error)
    @controller.record_request(:error)
    @controller.record_ping(:failure)

    # Metrics should be 0 before window completes
    assert_equal(0.0, @controller.metrics[:error_rate])

    # Move forward in time past the window size (5 seconds)
    time_travel(6.0) do
      @controller.update

      # First window metrics are now available
      assert_equal(1.0, @controller.metrics[:error_rate])
      assert_equal(1.0, @controller.metrics[:ping_failure_rate])

      # Record data in second window
      @controller.record_request(:success)
      @controller.record_request(:success)
      @controller.record_ping(:success)

      # Second window not complete yet, still showing first window metrics
      assert_equal(1.0, @controller.metrics[:error_rate])

      # Complete second window
      time_travel(6.0) do
        @controller.update

        # Now showing second window metrics
        assert_equal(0.0, @controller.metrics[:error_rate])
        assert_equal(0.0, @controller.metrics[:ping_failure_rate])
      end
    end
  end

  def test_current_window_counters_visible
    # Record data in current window
    @controller.record_request(:error)
    @controller.record_request(:success)
    @controller.record_request(:error)
    @controller.record_ping(:failure)
    @controller.record_ping(:success)

    # Current window counters should be visible in metrics
    metrics = @controller.metrics

    assert_equal({ success: 1, error: 2, rejected: 0 }, metrics[:current_window_requests])
    assert_equal({ success: 1, failure: 1 }, metrics[:current_window_pings])

    # But calculated rates are still from last completed window (0 initially)
    assert_equal(0.0, metrics[:error_rate])
    assert_equal(0.0, metrics[:ping_failure_rate])
  end

  def test_metrics_output
    @controller.record_request(:error)
    @controller.record_request(:success)
    @controller.record_ping(:failure)

    time_travel(1.0) do
      @controller.update
    end

    metrics = @controller.metrics

    assert(metrics.key?(:rejection_rate))
    assert(metrics.key?(:error_rate))
    assert(metrics.key?(:ping_failure_rate))
    assert(metrics.key?(:ideal_error_rate))
    assert(metrics.key?(:health_metric))
    assert(metrics.key?(:integral))
    assert(metrics.key?(:previous_error))
  end

  def test_pid_integration_behavior
    # Simulate a scenario where dependency starts failing
    5.times { @controller.record_request(:success) }

    time_travel(1.0) do
      @controller.update

      initial_rejection = @controller.rejection_rate

      # Errors start occurring
      time_travel(1.0) do
        10.times { @controller.record_request(:error) }
        3.times { @controller.record_ping(:failure) }

        time_travel(1.0) do
          @controller.update

          # Rejection rate should increase
          mid_rejection = @controller.rejection_rate

          assert_operator(mid_rejection, :>, initial_rejection)

          # Now dependency recovers
          time_travel(1.0) do
            20.times { @controller.record_request(:success) }
            10.times { @controller.record_ping(:success) }

            time_travel(1.0) do
              @controller.update

              # Rejection rate should decrease
              final_rejection = @controller.rejection_rate

              assert_operator(final_rejection, :<, mid_rejection)
            end
          end
        end
      end
    end
  end
end

class TestThreadSafePIDController < Minitest::Test
  include TimeHelper

  def setup
    @controller = Semian::ThreadSafePIDController.new(
      name: "thread_safe_test",
      kp: 1.0,
      ki: 0.1,
      kd: 0.01,
    )
  end

  def test_thread_safety
    threads = []
    errors = []

    # Create multiple threads that simultaneously update the controller
    10.times do |i|
      threads << Thread.new do
        100.times do
          if i.even?
            @controller.record_request(:error)
          else
            @controller.record_request(:success)
          end
          @controller.update
        end
      rescue => e
        errors << e
      end
    end

    threads.each(&:join)

    # No errors should have occurred
    assert_empty(errors)

    # Controller should be in a consistent state
    metrics = @controller.metrics

    assert_operator(metrics[:rejection_rate], :>=, 0.0)
    assert_operator(metrics[:rejection_rate], :<=, 1.0)
  end

  def test_concurrent_reads_and_writes
    write_thread = Thread.new do
      100.times do
        @controller.record_request([:success, :error].sample)
        @controller.update
      end
    end

    read_threads = 5.times.map do
      Thread.new do
        100.times do
          @controller.metrics
        end
      end
    end

    write_thread.join
    read_threads.each(&:join)

    # Should complete without deadlock or errors
    assert(true)
  end
end
