# frozen_string_literal: true

require "test_helper"
require "semian/timestamped_sliding_window"

class TestTimestampedSlidingWindow < Minitest::Test
  def setup
    @window = Semian::TimestampedSlidingWindow.new(window_size: 10)
  end

  def teardown
    @window.clear
  end

  def test_basic_observation_tracking
    current_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # Add some observations
    @window.add_observation(:success, current_time)
    @window.add_observation(:error, current_time + 1)
    @window.add_observation(:success, current_time + 2)
    @window.add_observation(:rejected, current_time + 3)

    counts = @window.get_counts(current_time + 3)

    assert_equal(2, counts[:success])
    assert_equal(1, counts[:error])
    assert_equal(1, counts[:rejected])
  end

  def test_sliding_window_removes_old_observations
    current_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # Add observations at different times
    @window.add_observation(:success, current_time)
    @window.add_observation(:error, current_time + 5)
    @window.add_observation(:success, current_time + 8)
    @window.add_observation(:error, current_time + 11) # This should remove the first observation

    # Check counts at t+11, should not include observation at t+0
    counts = @window.get_counts(current_time + 11)

    assert_equal(1, counts[:success]) # Only the one at t+8
    assert_equal(2, counts[:error]) # Both at t+5 and t+11
    assert_equal(0, counts[:rejected])
  end

  def test_calculate_error_rate
    current_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # Add observations
    @window.add_observation(:success, current_time)
    @window.add_observation(:success, current_time + 1)
    @window.add_observation(:error, current_time + 2)
    @window.add_observation(:success, current_time + 3)
    @window.add_observation(:error, current_time + 4)

    # 2 errors out of 5 total (3 success + 2 error)
    error_rate = @window.calculate_error_rate(current_time + 4)

    assert_in_delta(0.4, error_rate, 0.001)
  end

  def test_error_rate_with_rejected_requests
    current_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # Add observations including rejected
    @window.add_observation(:success, current_time)
    @window.add_observation(:error, current_time + 1)
    @window.add_observation(:rejected, current_time + 2)
    @window.add_observation(:rejected, current_time + 3)

    # Error rate should only consider success and error, not rejected
    # 1 error out of 2 total (1 success + 1 error)
    error_rate = @window.calculate_error_rate(current_time + 3)

    assert_in_delta(0.5, error_rate, 0.001)
  end

  def test_sliding_window_with_continuous_updates
    base_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # Simulate continuous updates every second for 15 seconds
    15.times do |i|
      timestamp = base_time + i

      # Add a mix of outcomes
      if i % 3 == 0
        @window.add_observation(:error, timestamp)
      else
        @window.add_observation(:success, timestamp)
      end
    end

    # At t+14, we should only have observations from t+5 to t+14 (10 seconds window)
    counts = @window.get_counts(base_time + 14)

    # From t+5 to t+14: t+6,9,12 are errors (3), rest are success (7)
    expected_errors = [6, 9, 12].count { |t| t >= 5 && t <= 14 }
    expected_success = 10 - expected_errors

    assert_equal(expected_success, counts[:success])
    assert_equal(expected_errors, counts[:error])
    assert_equal(0, counts[:rejected])
  end

  def test_empty_window_error_rate
    # Empty window should return 0 error rate
    error_rate = @window.calculate_error_rate

    assert_equal(0.0, error_rate)
  end

  def test_all_rejected_error_rate
    current_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # Only rejected requests
    @window.add_observation(:rejected, current_time)
    @window.add_observation(:rejected, current_time + 1)

    # No success or error requests means 0% error rate
    error_rate = @window.calculate_error_rate(current_time + 1)

    assert_equal(0.0, error_rate)
  end

  def test_clear_window
    current_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # Add some observations
    @window.add_observation(:success, current_time)
    @window.add_observation(:error, current_time + 1)

    assert_equal(2, @window.size)

    @window.clear

    assert_equal(0, @window.size)

    counts = @window.get_counts

    assert_equal(0, counts[:success])
    assert_equal(0, counts[:error])
    assert_equal(0, counts[:rejected])
  end

  def test_thread_safety
    window = Semian::ThreadSafeTimestampedSlidingWindow.new(window_size: 10)
    base_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    threads = []
    thread_count = 10
    observations_per_thread = 100

    thread_count.times do |i|
      threads << Thread.new do
        observations_per_thread.times do |j|
          timestamp = base_time + (j * 0.01) # Spread observations over 1 second
          outcome = [:success, :error, :rejected].sample
          window.add_observation(outcome, timestamp)
        end
      end
    end

    threads.each(&:join)

    # All observations should be within the window at base_time + 1
    counts = window.get_counts(base_time + 1)
    total = counts[:success] + counts[:error] + counts[:rejected]

    assert_equal(thread_count * observations_per_thread, total)
  ensure
    window&.clear
  end
end
