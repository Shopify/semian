require 'minitest/autorun'
require 'semian'

class TestSlidingTimeWindow < Minitest::Unit::TestCase
  def setup
    @max_size = 3
    @duration = 5

    @window = Semian::SlidingTimeWindow.new(max_size: @max_size, duration: @duration)
  end

  def test_append_and_read_last_from_timing_slide_window
    time = Time.now
    @window.push(time)

    assert_equal time, @window.last
    assert_equal 1, @window.size
  end

  def test_append_after_max_size_pops_first_element
    timestamps = [Time.now, Time.now, Time.now]
    timestamps.each { |t| @window.push(t) }

    assert_equal @max_size, @window.size
    assert_equal timestamps.first, @window.first
    assert_equal timestamps.last, @window.last

    timestamps << Time.now
    @window.push(timestamps.last)
    assert_equal @max_size, @window.size
    assert_equal timestamps[1], @window.first
    assert_equal timestamps.last, @window.last
  end

  def test_append_more_than_duration_after_first_element_pops
    past = Time.now - @duration - 1
    @window.push(past)

    assert_equal 1, @window.size

    now = Time.now
    @window.push(now)

    assert_equal 1, @window.size
    assert_equal now, @window.last
  end

  def test_append_doesnt_erase_boundary_of_window
    now = Time.now
    past = now - @duration
    @window.push(past)

    assert_equal 1, @window.size

    @window.push(now)

    assert_equal 2, @window.size
    assert_equal [past, now], @window.window
  end

  def test_append_more_than_duration_after_first_element_without_duration_doesnt_pop
    @window = Semian::SlidingTimeWindow.new(max_size: @max_size)

    past = Time.now - @duration - 1
    @window.push(past)

    assert_equal 1, @window.size

    now = Time.now
    @window.push(now)

    assert_equal 2, @window.size
  end
end
