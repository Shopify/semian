require 'test_helper'

class TestSimpleSlidingWindow < Minitest::Test
  def setup
    @sliding_window = ::Semian::ThreadSafe::SlidingWindow.new(:sliding_window_test, max_size: 6)
    @sliding_window.clear
  end

  def teardown
    @sliding_window.destroy
  end

  def test_sliding_window_push
    assert_equal(0, @sliding_window.size)
    @sliding_window << 1
    assert_sliding_window(@sliding_window, [1], 6)
    @sliding_window << 5
    assert_sliding_window(@sliding_window, [1, 5], 6)
  end

  def test_sliding_window_edge_falloff
    assert_equal(0, @sliding_window.size)
    @sliding_window << 0 << 1 << 2 << 3 << 4 << 5 << 6 << 7
    assert_sliding_window(@sliding_window, [2, 3, 4, 5, 6, 7], 6)
  end

  def test_sliding_window_reject
    @sliding_window << 0 << 1 << 2 << 3 << 4 << 5 << 6 << 7
    assert_equal(6, @sliding_window.size)
    assert_sliding_window(@sliding_window, [2, 3, 4, 5, 6, 7], 6)
    @sliding_window.reject! { |val| val <= 3 }
    assert_sliding_window(@sliding_window, [4, 5, 6, 7], 6)
  end

  def test_sliding_window_reject_failure
    @sliding_window << 0 << 1 << 2 << 3 << 4 << 5 << 6 << 7
    assert_equal(6, @sliding_window.size)
    assert_sliding_window(@sliding_window, [2, 3, 4, 5, 6, 7], 6)
    assert_raises ArgumentError do
      # This deletes from the middle of the array
      @sliding_window.reject! { |val| val == 3 }
    end
  end

  def resize_to_less_than_1_raises
    assert_raises ArgumentError do
      @sliding_window.resize_to 0
    end
  end

  private

  def assert_sliding_window(sliding_window, array, max_size)
    assert_equal(array, sliding_window.values)
    assert_equal(max_size, sliding_window.max_size)
  end
end
