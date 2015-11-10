require 'test_helper'

class TestSlidingWindow < MiniTest::Unit::TestCase
  def test_sliding_window_functionality
    run_test_with_sliding_window_classes do
      assert_equal(0, @sliding_window.size)
      @sliding_window << 1
      assert_correct_first_and_last_and_size(@sliding_window, 1, 1, 1, 6)
      @sliding_window << 5
      assert_correct_first_and_last_and_size(@sliding_window, 1, 5, 2, 6)
      @sliding_window.unshift(3)
      assert_correct_first_and_last_and_size(@sliding_window, 3, 5, 3, 6)
      @sliding_window.resize_to(3)
      assert_correct_first_and_last_and_size(@sliding_window, 3, 5, 3, 3)
      @sliding_window.resize_to(1)
      assert_correct_first_and_last_and_size(@sliding_window, 5, 5, 1, 1)
    end
  end

  def test_sliding_window_edge_falloff
    run_test_with_sliding_window_classes do
      assert_equal(0, @sliding_window.size)
      @sliding_window << 0 << 1 << 2 << 3 << 4 << 5 << 6 << 7
      assert_correct_first_and_last_and_size(@sliding_window, 2, 7, 6, 6)
      @sliding_window.shift
      assert_correct_first_and_last_and_size(@sliding_window, 3, 7, 5, 6)
      @sliding_window.clear
    end
  end

  private

  def sliding_window_classes
    @classes ||= retrieve_descendants(::Semian::SlidingWindow)
  end

  def run_test_with_sliding_window_classes(klasses = sliding_window_classes)
    klasses.each do |klass|
      begin
        @sliding_window = klass.new('TestSlidingWindow', 6, 0660)
        @sliding_window.clear
        yield(klass)
      ensure
        @sliding_window.destroy
      end
    end
  end

  def assert_correct_first_and_last_and_size(sliding_window, first, last, size, max_size)
    assert_equal(first, sliding_window.first)
    assert_equal(last, sliding_window.last)
    assert_equal(size, sliding_window.size)
    assert_equal(max_size, sliding_window.max_size)
  end

  def assert_sliding_windows_in_sync(sliding_window_1, sliding_window_2)
    # it only exposes ends, size, and max_size, so can only check those
    assert_equal(sliding_window_1.first, sliding_window_2.first)
    assert_equal(sliding_window_1.last, sliding_window_2.last)
    assert_equal(sliding_window_1.size, sliding_window_2.size)
    assert_equal(sliding_window_1.max_size, sliding_window_2.max_size)
  end
end
