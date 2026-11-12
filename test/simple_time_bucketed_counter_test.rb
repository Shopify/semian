# frozen_string_literal: true

require "test_helper"

module TimeBucketedCounterTests
  include TimeHelper

  def setup
    @counter = counter_class.new(window: 10)
  end

  def test_starts_empty
    assert_equal([0, 0], @counter.counts)
  end

  def test_counts_successes_and_failures
    3.times { @counter.record_success }
    2.times { @counter.record_failure }

    assert_equal([3, 2], @counter.counts)
  end

  def test_outcomes_inside_the_window_are_kept
    @counter.record_failure
    time_travel(8) do
      @counter.record_success

      assert_equal([1, 1], @counter.counts)
    end
  end

  def test_outcomes_outside_the_window_expire
    @counter.record_failure
    time_travel(10) do
      @counter.record_success

      assert_equal([1, 0], @counter.counts)
    end
  end

  def test_a_gap_longer_than_the_window_expires_everything
    @counter.record_success
    @counter.record_failure

    time_travel(100) { assert_equal([0, 0], @counter.counts) }
  end

  def test_clear_forgets_everything
    @counter.record_success
    @counter.record_failure
    @counter.clear

    assert_equal([0, 0], @counter.counts)
  end

  def test_clear_runs_its_block_before_forgetting
    @counter.record_failure
    seen = nil
    @counter.clear { seen = @counter.instance_variable_get(:@failures).sum }

    assert_equal(1, seen)
    assert_equal([0, 0], @counter.counts)
  end

  def test_a_clock_that_goes_backwards_keeps_recording
    @counter.record_success
    time_travel(-2) { @counter.record_failure }

    assert_equal([1, 1], @counter.counts)
  end

  def test_fractional_windows_round_up_to_a_whole_second
    counter = counter_class.new(window: 2.5)
    counter.record_failure

    time_travel(1) { assert_equal([0, 1], counter.counts) }
    time_travel(3) { assert_equal([0, 0], counter.counts) }
  end

  def test_reusing_a_bucket_does_not_revive_stale_outcomes
    @counter.record_success
    @counter.record_failure
    time_travel(10) do
      @counter.record_success

      assert_equal([1, 0], @counter.counts)
    end
  end

  def test_a_gap_shorter_than_the_window_expires_only_the_older_outcomes
    @counter.record_failure
    time_travel(4) { @counter.record_success }

    time_travel(12) { assert_equal([1, 0], @counter.counts) }
    time_travel(16) { assert_equal([0, 0], @counter.counts) }
  end

  def test_matches_a_recount_of_the_outcomes_in_the_window_across_gaps_and_clock_jumps
    random = Random.new(42)
    [1, 2, 3, 10, 60].each do |window|
      now = frontier = 1_000
      outcomes = []
      counter = Class.new(counter_class) { define_method(:current_second) { now } }.new(window: window)
      500.times do
        now += [0, 0, 1, 1, 2, window - 1, window, window + 1, 10 * window, -1, -window].sample(random: random)
        case random.rand(8)
        when 0
          counter.clear
          outcomes.clear
          frontier = now
        when 1..3
          counter.record_success
          outcomes << [frontier = [frontier, now].max, :success]
        when 4..5
          counter.record_failure
          outcomes << [frontier = [frontier, now].max, :failure]
        else
          frontier = [frontier, now].max
          recent = outcomes.select { |second, _| second > frontier - window }.map(&:last)

          assert_equal([recent.count(:success), recent.count(:failure)], counter.counts)
          assert_equal(counter.counts, [:@successes, :@failures].map { |buckets| counter.instance_variable_get(buckets).sum })
        end
      end
    end
  end
end

class TestSimpleTimeBucketedCounter < Minitest::Test
  include TimeBucketedCounterTests

  def counter_class
    Semian::Simple::TimeBucketedCounter
  end
end

class TestThreadSafeTimeBucketedCounter < Minitest::Test
  include TimeBucketedCounterTests

  def counter_class
    Semian::ThreadSafe::TimeBucketedCounter
  end

  def test_concurrent_recording_loses_no_updates
    threads = 8.times.map do
      Thread.new do
        1000.times do
          @counter.record_success
          @counter.record_failure
        end
      end
    end
    threads.each(&:join)

    assert_equal([8000, 8000], @counter.counts)
  end

  def test_nothing_is_recorded_between_the_block_of_clear_and_clearing
    @counter.record_failure
    recorder = nil
    @counter.clear do
      recorder = Thread.new { @counter.record_success }
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
      Thread.pass while recorder.status == "run" && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline

      assert_equal("sleep", recorder.status, "Expected the success to wait for the clear")
    end

    assert(recorder.join(5), "Expected the success to be recorded once cleared")
    assert_equal([1, 0], @counter.counts)
  end

  def test_nothing_is_recorded_while_synchronized
    recorder = nil
    @counter.synchronize do
      recorder = Thread.new { @counter.record_success }
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
      Thread.pass while recorder.status == "run" && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline

      assert_equal("sleep", recorder.status, "Expected the success to wait")
      assert_equal([0, 0], [@counter.instance_variable_get(:@successes).sum, @counter.instance_variable_get(:@failures).sum])
    end

    assert(recorder.join(5), "Expected the success to be recorded once released")
    assert_equal([1, 0], @counter.counts)
  end
end
