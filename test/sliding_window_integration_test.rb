# frozen_string_literal: true

require "test_helper"
require "semian/adaptive_circuit_breaker"
require "semian/pid_controller"
require "semian/timestamped_sliding_window"

class TestSlidingWindowIntegration < Minitest::Test
  def setup
    @base_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Process.stubs(:clock_gettime).with(Process::CLOCK_MONOTONIC).returns(@base_time)

    @controller = Semian::PIDController.new(
      kp: 1.0,
      ki: 0.1,
      kd: 0.01,
      window_size: 10, # 10-second lookback window
      initial_history_duration: 10000,
      initial_error_rate: 0.01,
    )
  end

  def teardown
    @controller.reset
    Process.unstub(:clock_gettime)
  end

  def test_sliding_window_with_1_second_updates
    # Simulate 15 seconds of activity with updates every second
    # The window should only consider the last 10 seconds

    15.times do |second|
      current_time = @base_time + second
      Process.stubs(:clock_gettime).with(Process::CLOCK_MONOTONIC).returns(current_time)

      # Add some requests
      if second < 5
        # First 5 seconds: low error rate (1%)
        99.times { @controller.record_request(:success, current_time) }
        1.times { @controller.record_request(:error, current_time) }
      elsif second < 10
        # Next 5 seconds: high error rate (10%)
        90.times { @controller.record_request(:success, current_time) }
        10.times { @controller.record_request(:error, current_time) }
      else
        # Last 5 seconds: medium error rate (5%)
        95.times { @controller.record_request(:success, current_time) }
        5.times { @controller.record_request(:error, current_time) }
      end

      # Update controller every second (sliding by 1 second)
      @controller.update if second > 0
    end

    # At second 15, the window should contain seconds 5-14
    # That's 5 seconds of 10% error rate + 5 seconds of 5% error rate
    # Average error rate should be around 7.5%
    metrics = @controller.metrics

    # The actual error rate in the current window
    counts = metrics[:current_window_requests]
    total = counts[:success] + counts[:error]

    # We should have 10 seconds worth of data (seconds 5-14)
    # 5 seconds of 90 success + 10 error = 450 success + 50 error
    # 5 seconds of 95 success + 5 error = 475 success + 25 error
    # Total: 925 success + 75 error = 1000 total
    assert_equal(1000, total, "Should have exactly 10 seconds of data")
    assert_equal(925, counts[:success], "Should have correct success count")
    assert_equal(75, counts[:error], "Should have correct error count")

    # Error rate should be 75/1000 = 7.5%
    assert_in_delta(0.075, metrics[:error_rate], 0.001)
  end

  def test_old_observations_are_removed
    # Add observations at different times
    time1 = @base_time
    time2 = @base_time + 5
    time3 = @base_time + 11 # This is beyond the 10-second window from time1

    # Add observations at time1
    Process.stubs(:clock_gettime).with(Process::CLOCK_MONOTONIC).returns(time1)
    50.times { @controller.record_request(:success, time1) }
    5.times { @controller.record_request(:error, time1) }

    # Add observations at time2
    Process.stubs(:clock_gettime).with(Process::CLOCK_MONOTONIC).returns(time2)
    40.times { @controller.record_request(:success, time2) }
    10.times { @controller.record_request(:error, time2) }

    # Update at time3 - observations from time1 should be removed
    Process.stubs(:clock_gettime).with(Process::CLOCK_MONOTONIC).returns(time3)
    @controller.update

    # Only observations from time2 should remain
    counts = @controller.metrics[:current_window_requests]

    assert_equal(40, counts[:success], "Only recent success counts should remain")
    assert_equal(10, counts[:error], "Only recent error counts should remain")
  end

  def test_continuous_sliding_behavior
    # Test that the sliding window correctly maintains a 10-second window
    # as we continuously add data and update

    window = Semian::TimestampedSlidingWindow.new(window_size: 10)

    # Simulate 20 seconds of data with updates every second
    20.times do |second|
      current_time = @base_time + second

      # Add 10 observations per second
      10.times do
        outcome = second < 10 ? :success : :error
        window.add_observation(outcome, current_time)
      end

      # Check that we maintain the correct window size
      observations = window.get_observations_in_window(current_time)

      if second < 10
        # Should have all observations from start to current
        expected_count = (second + 1) * 10

        assert_equal(expected_count, observations.size, "At second #{second}, should have #{expected_count} observations")
      else
        # Should have exactly 10 seconds worth (100 observations)
        assert_equal(100, observations.size, "At second #{second}, should have exactly 100 observations (10 seconds worth)")

        # All observations should be within the last 10 seconds
        observations.each do |obs|
          assert_operator(obs[:timestamp], :>=, current_time - 10, "Observation should be within last 10 seconds")
          assert_operator(obs[:timestamp], :<=, current_time, "Observation should not be in the future")
        end
      end
    end
  end
end
