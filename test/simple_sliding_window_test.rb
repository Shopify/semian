# frozen_string_literal: true

require "test_helper"

class TestSimpleSlidingWindow < Minitest::Test
  def setup
    @sliding_window = ::Semian::ThreadSafe::SlidingWindow.new(max_size: 6)
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

  def resize_to_less_than_1_raises
    assert_raises(ArgumentError) do
      @sliding_window.resize_to(0)
    end
  end

  private

  def assert_sliding_window(sliding_window, array, max_size)
    # Get private member, the sliding_window doesn't expose the entire array
    data = sliding_window.instance_variable_get("@window")

    assert_equal(array, data)
    assert_equal(max_size, sliding_window.max_size)
  end
end
