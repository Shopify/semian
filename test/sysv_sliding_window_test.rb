require 'test_helper'

class TestSysVSlidingWindow < MiniTest::Unit::TestCase
  CLASS = ::Semian::SysV::SlidingWindow

  def setup
    @sliding_window = CLASS.new(max_size: 6,
                                name: 'TestSysVSlidingWindow',
                                permissions: 0660)
    @sliding_window.clear
  end

  def teardown
    @sliding_window.destroy
  end

  include TestSimpleSlidingWindow::SlidingWindowTestCases

  def test_forcefully_killing_worker_holding_on_to_semaphore_releases_it
    Timeout.timeout(1) do # assure dont hang
      @sliding_window << 100
      assert_equal 100, @sliding_window.first
    end

    reader, writer = IO.pipe
    pid = fork do
      reader.close
      sliding_window_2 = CLASS.new(max_size: 6,
                                   name: 'TestSysVSlidingWindow',
                                   permissions: 0660)
      sliding_window_2.synchronize do
        writer.puts "Done"
        writer.close
        sleep
      end
    end

    reader.gets
    Process.kill(9, pid)

    Timeout.timeout(1) do # assure dont hang
      @sliding_window << 100
      assert_equal(100, @sliding_window.first)
    end
  end

  def test_sliding_window_memory_is_actually_shared
    assert_equal 0, @sliding_window.size
    sliding_window_2 = CLASS.new(max_size: 6,
                                 name: 'TestSysVSlidingWindow',
                                 permissions: 0660)
    assert_equal 0, sliding_window_2.size

    large_number = (Time.now.to_f * 1000).to_i
    @sliding_window << large_number
    assert_sliding_window(@sliding_window, [large_number], 6)
    assert_sliding_windows_in_sync(@sliding_window, sliding_window_2)
    sliding_window_2 << 6 << 4 << 3 << 2
    assert_sliding_window(@sliding_window, [large_number, 6, 4, 3, 2], 6)
    assert_sliding_windows_in_sync(@sliding_window, sliding_window_2)

    @sliding_window.clear
    assert_sliding_window(@sliding_window, [], 6)
    assert_sliding_windows_in_sync(@sliding_window, sliding_window_2)
  end

  def test_restarting_worker_should_not_reset_queue
    @sliding_window << 10 << 20 << 30
    sliding_window_2 = CLASS.new(max_size: 6,
                                 name: 'TestSysVSlidingWindow',
                                 permissions: 0660)
    assert_sliding_window(sliding_window_2, [10, 20, 30], 6)
    sliding_window_2.pop
    assert_sliding_window(sliding_window_2, [10, 20], 6)
    assert_sliding_windows_in_sync(@sliding_window, sliding_window_2)

    sliding_window_3 = CLASS.new(max_size: 6,
                                 name: 'TestSysVSlidingWindow',
                                 permissions: 0660)
    assert_sliding_window(sliding_window_3, [10, 20], 6)
    sliding_window_3.pop
    assert_sliding_window(@sliding_window, [10], 6)
    assert_sliding_windows_in_sync(@sliding_window, sliding_window_2)
  end

  def test_other_workers_automatically_switching_to_new_memory_resizing_up_or_down
    # Test explicit resizing, and resizing through making new memory associations

    # B resize down through init
    sliding_window_2 = CLASS.new(max_size: 4,
                                 name: 'TestSysVSlidingWindow',
                                 permissions: 0660)
    sliding_window_2 << 80 << 90 << 100 << 110 << 120
    assert_sliding_window(sliding_window_2, [90, 100, 110, 120], 4)
    assert_sliding_windows_in_sync(@sliding_window, sliding_window_2)

    # A explicit resize down,
    @sliding_window.resize_to(2)
    assert_sliding_windows_in_sync(@sliding_window, sliding_window_2)
    assert_sliding_window(@sliding_window, [110, 120], 2)

    # B resize up through init
    sliding_window_2 = CLASS.new(max_size: 4,
                                 name: 'TestSysVSlidingWindow',
                                 permissions: 0660)
    assert_sliding_windows_in_sync(@sliding_window, sliding_window_2)
    assert_sliding_window(@sliding_window, [110, 120], 4)

    # A explicit resize up
    @sliding_window.resize_to(6)
    @sliding_window << 130
    assert_sliding_windows_in_sync(@sliding_window, sliding_window_2)
    assert_sliding_window(@sliding_window, [110, 120, 130], 6)

    # B resize down through init
    sliding_window_2 = CLASS.new(max_size: 2,
                                 name: 'TestSysVSlidingWindow',
                                 permissions: 0660)
    assert_sliding_windows_in_sync(@sliding_window, sliding_window_2)
    assert_sliding_window(@sliding_window, [120, 130], 2)

    # A explicit resize up
    @sliding_window.resize_to(4)
    assert_sliding_windows_in_sync(@sliding_window, sliding_window_2)
    assert_sliding_window(@sliding_window, [120, 130], 4)

    # B resize up through init
    sliding_window_2 = CLASS.new(max_size: 6,
                                 name: 'TestSysVSlidingWindow',
                                 permissions: 0660)
    assert_sliding_windows_in_sync(@sliding_window, sliding_window_2)
    assert_sliding_window(@sliding_window, [120, 130], 6)

    # B resize, but no final size change
    sliding_window_2 << 140 << 150 << 160 << 170
    sliding_window_2.resize_to(4)
    sliding_window_2 << 180
    sliding_window_2.resize_to(6)
    assert_sliding_window(@sliding_window, [150, 160, 170, 180], 6)
    assert_sliding_windows_in_sync(@sliding_window, sliding_window_2)
  end

  private

  def assert_sliding_window(sliding_window, array, max_size)
    assert_correct_first_and_last_and_size(sliding_window, array.first, array.last, array.size, max_size)
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

  include TestSimpleSlidingWindow::SlidingWindowUtilityMethods
end
