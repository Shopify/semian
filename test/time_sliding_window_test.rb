require 'test_helper'

class TestTimeSlidingWindow < Minitest::Test
  def setup
    @sliding_window = ::Semian::ThreadSafe::TimeSlidingWindow.new(0.5, -> { Time.now.to_f * 1000 }) # Timecop doesn't work with a monotonic clock
    @sliding_window.clear
    Timecop.freeze
  end

  def teardown
    @sliding_window.destroy
    Timecop.return
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
    Timecop.travel(0.501) do
      assert_sliding_window(@sliding_window, [], 500)
    end
  end

  def test_sliding_window_edge_falloff
    assert_equal(0, @sliding_window.size)
    @sliding_window << 0 << 1 << 2 << 3 << 4 << 5 << 6 << 7
    assert_sliding_window(@sliding_window, [0, 1, 2, 3, 4, 5, 6, 7], 500)
    Timecop.travel(0.251) do
      @sliding_window << 8 << 9 << 10
    end

    Timecop.travel(0.251 * 2) do
      assert_sliding_window(@sliding_window, [8, 9, 10], 500)
      @sliding_window << 11
    end
    Timecop.travel(0.251 * 3) do
      assert_sliding_window(@sliding_window, [11], 500)
    end
  end

  def test_sliding_window_count
    @sliding_window << true << false << true << false << true << true << true
    assert_equal(5, @sliding_window.count { |e| e == true })
    assert_equal(2, @sliding_window.count { |e| e == false })
  end

  def test_each_with_object
    assert_equal(0, @sliding_window.size)
    @sliding_window << [false, 1] << [false, 2] << [true, 1] << [true, 3]
    result = @sliding_window.each_with_object([0.0, 0.0]) do |entry, sum|
      if entry[0] == true
        sum[0] = entry[1] + sum[0]
      else
        sum[1] = entry[1] + sum[1]
      end
    end

    assert_equal([4.0, 3.0], result)
  end

  private

  def assert_sliding_window(sliding_window, array, time_window_millis)
    # each_with_object will remove old entries first
    data = sliding_window.each_with_object([]) { |v, data| data.append(v) }
    assert_equal(array, data)
    assert_equal(time_window_millis, sliding_window.time_window_ms)
  end
end
