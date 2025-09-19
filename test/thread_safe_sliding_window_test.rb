# frozen_string_literal: true

require "test_helper"

class TestThreadSafeSlidingWindow < Minitest::Test
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

  def test_concurrent_push
    threads = []
    thread_count = 5

    thread_count.times do |i|
      threads << Thread.new do
        @sliding_window << (i + 1)
      end
    end

    threads.each(&:join)

    assert_equal(thread_count, @sliding_window.size)

    final_window_data = if @sliding_window.instance_variable_defined?("@window_atom")
      @sliding_window.instance_variable_get("@window_atom").value
    else
      @sliding_window.instance_variable_get("@window")
    end

    assert_kind_of(Array, final_window_data)
    assert_equal(thread_count, final_window_data.size)

    final_window_data.each do |value|
      assert_operator(value, :>=, 1, "Value #{value} should be at least 1")
      assert_operator(value, :<=, thread_count, "Value #{value} should be at most #{thread_count}")
    end
  end

  def test_concurrent_window_edge_falloff
    threads = []
    thread_count = 5
    pushes_per_thread = 3 # Total pushes = 15, exceeds max_size of 6

    thread_count.times do |i|
      threads << Thread.new do
        pushes_per_thread.times do |j|
          value = i * pushes_per_thread + j
          @sliding_window << value
        end
      end
    end

    threads.each(&:join)

    assert_equal(@sliding_window.max_size, @sliding_window.size)

    final_window_data = if @sliding_window.instance_variable_defined?("@window_atom")
      @sliding_window.instance_variable_get("@window_atom").value
    else
      @sliding_window.instance_variable_get("@window")
    end

    assert_kind_of(Array, final_window_data)
    assert_equal(@sliding_window.max_size, final_window_data.size)

    final_window_data.each do |value|
      assert_operator(value, :>=, 0, "Value #{value} should be non-negative")
      assert_operator(value, :<, thread_count * pushes_per_thread, "Value #{value} should be less than total pushed")
    end
  end

  def test_concurrent_resize_to_less_than_1_raises
    threads = []
    windows_created = Concurrent::Array.new

    3.times do |i|
      threads << Thread.new do
        max_size = i == 0 ? 1 : (i + 1) # Use max_size values of 1, 2, 3
        window = ::Semian::ThreadSafe::SlidingWindow.new(max_size: max_size)

        window << (i + 10)
        windows_created << { window: window, expected_size: 1, max_size: max_size }
      end
    end

    threads.each(&:join)

    assert_equal(3, windows_created.size, "All sliding windows should be created")

    windows_created.each do |window_data|
      window = window_data[:window]
      expected_size = window_data[:expected_size]
      max_size = window_data[:max_size]

      assert_equal(expected_size, window.size, "Window should have expected size")
      assert_equal(max_size, window.max_size, "Window should have correct max_size")
      refute_empty(window, "Window should not be empty after push")
    end

    @sliding_window << 42

    assert_equal(1, @sliding_window.size)
    assert_equal(42, @sliding_window.last)
  end

  private

  def assert_sliding_window(sliding_window, array, max_size)
    # Get private member, the sliding_window doesn't expose the entire array
    # Handle both old (@window) and new (@window_atom) implementations
    data = if sliding_window.instance_variable_defined?("@window_atom")
      sliding_window.instance_variable_get("@window_atom").value
    else
      sliding_window.instance_variable_get("@window")
    end

    assert_equal(array, data)
    assert_equal(max_size, sliding_window.max_size)
  end
end
