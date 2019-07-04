require 'test_helper'

class TestSimpleSlidingWindow < Minitest::Test
  def setup
    id = Time.now.strftime('%H:%M:%S.%N')
    @sliding_window = ::Semian::ThreadSafe::SlidingWindow.new(id, max_size: 6)
    @sliding_window.clear
  end

  def teardown
    @sliding_window.destroy unless @sliding_window.nil?
  end

  def test_clear
    id = Time.now.strftime('%H:%M:%S.%N')
    window = ::Semian::ThreadSafe::SlidingWindow.new(id, max_size: 6)
    window << 1 << 2 << 3
    assert_equal(3, window.size)
    window.clear
    assert_equal(0, window.size)
  end

  def test_destroy
    id = Time.now.strftime('%H:%M:%S.%N')
    window = ::Semian::ThreadSafe::SlidingWindow.new(id, max_size: 6)
    window << 1 << 2 << 3
    assert_equal(3, window.size)
    window.destroy
    assert_equal(0, window.size)
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

  def test_sliding_window_reject_non_contiguous
    @sliding_window << 0 << 1 << 2 << 3 << 4 << 5 << 6 << 7
    assert_equal(6, @sliding_window.size)
    assert_sliding_window(@sliding_window, [2, 3, 4, 5, 6, 7], 6)
    @sliding_window.reject! { |val| val == 3 }
    assert_sliding_window(@sliding_window, [2, 4, 5, 6, 7], 6)
  end

  def test_resize_to_less_than_1_raises
    assert_raises ArgumentError do
      @sliding_window.max_size = 0
    end
  end

  def test_resize_to_1_works
    assert_sliding_window(@sliding_window, [], 6)
    @sliding_window.max_size = 1
    assert_sliding_window(@sliding_window, [], 1)
  end

  def test_resize_to_simple
    id = Time.now.strftime('%H:%M:%S.%N')
    window = ::Semian::ThreadSafe::SlidingWindow.new(id, max_size: 4)
    window << 0 << 1
    assert_sliding_window(window, [0, 1], 4)
    window.max_size = 8
    assert_sliding_window(window, [0, 1], 8)
    window << 2 << 3 << 4 << 5
    assert_sliding_window(window, [0, 1, 2, 3, 4, 5], 8)
  end

  def test_resize_to_simple_full
    id = Time.now.strftime('%H:%M:%S.%N')
    window = ::Semian::ThreadSafe::SlidingWindow.new(id, max_size: 4)
    window << 0 << 1 << 2 << 3
    assert_sliding_window(window, [0, 1, 2, 3], 4)
    window.max_size = 8
    assert_sliding_window(window, [0, 1, 2, 3], 8)
    window << 4 << 5
    assert_sliding_window(window, [0, 1, 2, 3, 4, 5], 8)
  end

  def test_resize_to_simple_floating
    id = Time.now.strftime('%H:%M:%S.%N')
    window = ::Semian::ThreadSafe::SlidingWindow.new(id, max_size: 4)
    window << 0 << 1 << 2 << 3
    assert_sliding_window(window, [0, 1, 2, 3], 4)
    window.reject! { |val| val < 2 }
    assert_sliding_window(window, [2, 3], 4)
    window.max_size = 8
    assert_sliding_window(window, [2, 3], 8)
    window << 4 << 5
    assert_sliding_window(window, [2, 3, 4, 5], 8)
  end

  def test_resize_to_hard
    id = Time.now.strftime('%H:%M:%S.%N')
    window = ::Semian::ThreadSafe::SlidingWindow.new(id, max_size: 4)
    window << 0 << 1 << 2 << 3 << 4 << 5
    assert_sliding_window(window, [2, 3, 4, 5], 4)
    window.max_size = 8
    assert_sliding_window(window, [2, 3, 4, 5], 8)
    window << 6 << 7
    assert_sliding_window(window, [2, 3, 4, 5, 6, 7], 8)
    window << 8 << 9
    assert_sliding_window(window, [2, 3, 4, 5, 6, 7, 8, 9], 8)
  end

  def test_resize_to_shrink_simple
    id = Time.now.strftime('%H:%M:%S.%N')
    window = ::Semian::ThreadSafe::SlidingWindow.new(id, max_size: 4)
    window << 0 << 1
    assert_sliding_window(window, [0, 1], 4)
    window.max_size = 2
    assert_sliding_window(window, [0, 1], 2)
  end

  def test_resize_to_shrink_simple_full
    id = Time.now.strftime('%H:%M:%S.%N')
    window = ::Semian::ThreadSafe::SlidingWindow.new(id, max_size: 4)
    window << 0 << 1 << 2 << 3
    assert_sliding_window(window, [0, 1, 2, 3], 4)
    window.max_size = 2
    assert_sliding_window(window, [2, 3], 2)
  end

  def test_resize_to_shrink_hard
    id = Time.now.strftime('%H:%M:%S.%N')
    window = ::Semian::ThreadSafe::SlidingWindow.new(id, max_size: 4)
    window << 0 << 1 << 2 << 3 << 4 << 5
    assert_sliding_window(window, [2, 3, 4, 5], 4)
    window.max_size = 2
    assert_sliding_window(window, [4, 5], 2)
  end

  def test_resize_to_shrink_all_index
    8.times do |offset|
      id = Time.now.strftime("%H:%M:%S.%N-#{offset}")
      window = ::Semian::ThreadSafe::SlidingWindow.new(id, max_size: 4)
      offset.times { window << offset }
      window << 0 << 1 << 2 << 3
      assert_sliding_window(window, [0, 1, 2, 3], 4)
      window.max_size = 2
      assert_sliding_window(window, [2, 3], 2)
    end
  end

  def test_resize_to_grow_all_index
    8.times do |offset|
      id = Time.now.strftime("%H:%M:%S.%N-#{offset}")
      window = ::Semian::ThreadSafe::SlidingWindow.new(id, max_size: 4)
      offset.times { window << offset }
      window << 0 << 1 << 2 << 3
      assert_sliding_window(window, [0, 1, 2, 3], 4)
      window.max_size = 8
      assert_sliding_window(window, [0, 1, 2, 3], 8)
      window << 4 << 5 << 6 << 7
      assert_sliding_window(window, [0, 1, 2, 3, 4, 5, 6, 7], 8)
      window << 8 << 9
      assert_sliding_window(window, [2, 3, 4, 5, 6, 7, 8, 9], 8)
    end
  end

  def test_scale_factor
    pids = []
    skip unless ENV['SEMIAN_CIRCUIT_BREAKER_IMPL'] == 'host'

    id = Time.now.strftime("%H:%M:%S.%N")
    window = ::Semian::ThreadSafe::SlidingWindow.new(id, max_size: 1, scale_factor: 0.5)

    fork_worker = Proc.new do |i|
      pid = fork do
        # TODO(michaelkipper): We need to create a bulkhead here, because the sliding window
        #                      has a coupling to it via the registered worker semaphore. This
        #                      sucks, and should be removed by refactoring the bulkhead out of
        #                      the Semian resource concept.
        ::Semian::Resource.new(id, tickets: 1)
        window = ::Semian::ThreadSafe::SlidingWindow.new(id, max_size: 10, scale_factor: 0.5)
        window << (i * 100)
        sleep(3600)
      end

      puts "Forker worker #{pid}"
      sleep(0.1)
      pid
    end

    pids << fork_worker.call(1)
    assert_equal(10, window.max_size)
    pids << fork_worker.call(2)
    assert_equal(10, window.max_size)
    pids << fork_worker.call(3)
    assert_equal(15, window.max_size)
    pids << fork_worker.call(4)
    assert_equal(20, window.max_size)

    assert_equal(4, window.size)
  ensure
    pids.each do |pid|
      begin
        Process.kill('TERM', pid)
      rescue
        nil
      end
    end
  end

  def test_huge_sliding_window
    id = Time.now.strftime('%H:%M:%S.%N')
    window = ::Semian::ThreadSafe::SlidingWindow.new(id, max_size: 1000)
    4000.times do |i|
      window << i
    end
  end

  def test_huge_sliding_window_fails
    id = Time.now.strftime('%H:%M:%S.%N')
    assert_raises ArgumentError do
      ::Semian::ThreadSafe::SlidingWindow.new(id, max_size: 1001)
    end
  end

  private

  def assert_sliding_window(sliding_window, array, max_size)
    assert_equal(array, sliding_window.values, "Window contents were different")
    assert_equal(max_size, sliding_window.max_size, "Window max_size was not equal")
  end
end
