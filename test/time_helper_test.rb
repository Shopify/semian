# frozen_string_literal: true

require "test_helper"

class TestTimeHelper < Minitest::Test
  def test_time_monotonic_travel_past
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    current = now + 1
    time_travel(-6) do
      current = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    assert(now > current, "now #{now} should be bigger than current #{current}")
  end

  def test_time_monotonic_travel_future
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    current = now - 1
    time_travel(6) do
      current = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    assert(now + 5 < current, "now #{now} should be less than current #{current} at least by 5 secs")
  end

  def test_time_travel_past
    now = Time.now
    current = now + 1
    time_travel(-6) do
      current = Time.now
    end

    assert(now > current, "now #{now} should be bigger than current #{current}")
  end

  def test_time_travel_future
    now = Time.now
    current = now - 1
    time_travel(6) do
      current = Time.now
    end

    assert(now + 5 < current, "now #{now} should be less than current #{current} at least by 5 secs")
  end
end
