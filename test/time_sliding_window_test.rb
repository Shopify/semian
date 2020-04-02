require 'test_helper'

class TestTimeSlidingWindow < Minitest::Test
  def setup
    @sliding_window = ::Semian::ThreadSafe::TimeSlidingWindow.new(0.5) # Timecop doesn't work with a monotonic clock
    @sliding_window.clear
  end

  def teardown
    @sliding_window.destroy
  end

  def test_sliding_window_push
    assert_equal(0, @sliding_window.size)
    @sliding_window << 1
    assert_sliding_window(@sliding_window, [1], 500)
    @sliding_window << 5
    assert_sliding_window(@sliding_window, [1, 5], 500)
  end

  def test_special_everything_too_old
    @sliding_window << 0 << 1
    sleep(0.501)
    assert_sliding_window(@sliding_window, [], 500)
  end


  def test_sliding_window_edge_falloff
    assert_equal(0, @sliding_window.size)
    @sliding_window << 0 << 1 << 2 << 3 << 4 << 5 << 6 << 7
    assert_sliding_window(@sliding_window, [0, 1, 2, 3, 4, 5, 6, 7], 500)
    sleep(0.251)
    @sliding_window << 8 << 9 << 10
    sleep(0.251)
    assert_sliding_window(@sliding_window, [8, 9, 10], 500)
    @sliding_window << 11
    sleep(0.251)
    assert_sliding_window(@sliding_window, [11], 500)
  end

  def test_sliding_window_count
    @sliding_window << true << false << true << false << true << true << true
    assert_equal(5, @sliding_window.count(true))
    assert_equal(2, @sliding_window.count(false))
  end

  def test_issue
    @window = @sliding_window.instance_variable_get("@window")
    @window << ::Semian::ThreadSafe::TimeSlidingWindow::Pair.new(338019700.707, true)
    @window << ::Semian::ThreadSafe::TimeSlidingWindow::Pair.new(338019701.707, true)
    @sliding_window << false
    puts('break')
  end

  private

  def assert_sliding_window(sliding_window, array, time_window_millis)
    # Get private member, the sliding_window doesn't expose the entire array
    sliding_window.remove_old
    data = sliding_window.instance_variable_get("@window").map { |pair| pair.tail }
    assert_equal(array, data)
    assert_equal(time_window_millis, sliding_window.time_window_millis)
  end
end
