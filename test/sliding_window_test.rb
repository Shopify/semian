require 'test_helper'

class TestSlidingWindow < MiniTest::Unit::TestCase
  class FakeSysVSlidingWindow < Semian::SlidingWindow
    class << self
      attr_accessor :resources
    end
    self.resources = {}
    attr_accessor :name
    def self.new(name, size, permissions)
      obj = resources[name] ||= super
      obj.name = name
      obj.resize_to(size)
      obj
    end

    def destroy
      self.class.resources.delete(@name)
      super
    end

    def shared?
      true
    end
  end

  def setup
    @sliding_window = Semian::SysVSlidingWindow.new('TestSlidingWindow', 6, 0660)
    @sliding_window.clear
  end

  def test_forcefully_killing_worker_holding_on_to_semaphore_releases_it
    Timeout.timeout(1) do # assure dont hang
      @sliding_window << 100
      assert_equal 100, @sliding_window.first
    end

    pid = fork do
      sliding_window_2 = Semian::SysVSlidingWindow.new('TestSlidingWindow', 6, 0660)
      sliding_window_2.execute_atomically { sleep }
    end

    sleep 1
    Process.kill('KILL', pid)
    Process.waitall

    Timeout.timeout(1) do # assure dont hang
      @sliding_window << 100
      assert_equal(100, @sliding_window.first)
    end
  end

  def test_sliding_window_edge_falloff
    test_block = proc do |sliding_window|
      assert_equal(0, sliding_window.size)
      sliding_window << 0 << 1 << 2 << 3 << 4 << 5 << 6 << 7
      assert_correct_first_and_last_and_size(sliding_window, 2, 7, 6, 6)
      sliding_window.shift
      assert_correct_first_and_last_and_size(sliding_window, 3, 7, 5, 6)
      sliding_window.clear
    end
    test_block.call(@sliding_window)
    teardown
    @sliding_window = Semian::SlidingWindow.new('TestSlidingWindow', 6, 0660)
    test_block.call(@sliding_window)
  end

  def test_sliding_window_memory_is_actually_shared
    run_test_once_with_sysv_and_once_without_sysv_to_assert_correctness do |klass|
      next unless @sliding_window.shared?
      assert_equal 0, @sliding_window.size
      sliding_window_2 = klass.new('TestSlidingWindow', 6, 0660)
      assert_equal 0, sliding_window_2.size

      large_number = (Time.now.to_f * 1000).to_i
      @sliding_window << large_number
      assert_correct_first_and_last_and_size(@sliding_window, large_number, large_number, 1, 6)
      assert_correct_first_and_last_and_size(sliding_window_2, large_number, large_number, 1, 6)
      sliding_window_2 << 6 << 4 << 3 << 2
      assert_correct_first_and_last_and_size(@sliding_window, large_number, 2, 5, 6)
      assert_correct_first_and_last_and_size(sliding_window_2, large_number, 2, 5, 6)

      @sliding_window.clear
      assert_correct_first_and_last_and_size(@sliding_window, nil, nil, 0, 6)
      assert_correct_first_and_last_and_size(sliding_window_2, nil, nil, 0, 6)
    end
  end

  def test_restarting_worker_should_not_reset_queue
    run_test_once_with_sysv_and_once_without_sysv_to_assert_correctness do |klass|
      next unless @sliding_window.shared?
      @sliding_window << 10 << 20 << 30
      sliding_window_2 = klass.new('TestSlidingWindow', 6, 0660)
      assert_correct_first_and_last_and_size(@sliding_window, 10, 30, 3, 6)
      sliding_window_2.pop
      assert_sliding_windows_in_sync(@sliding_window, sliding_window_2)

      sliding_window_3 = klass.new('TestSlidingWindow', 6, 0660)
      assert_correct_first_and_last_and_size(@sliding_window, 10, 20, 2, 6)
      sliding_window_3.pop
      assert_correct_first_and_last_and_size(@sliding_window, 10, 10, 1, 6)
      assert_sliding_windows_in_sync(@sliding_window, sliding_window_2)
      @sliding_window.clear
    end
  end

  def test_other_workers_automatically_switching_to_new_memory_resizing_up_or_down
    run_test_once_with_sysv_and_once_without_sysv_to_assert_correctness do |klass|
      next unless @sliding_window.shared?
      # Test explicit resizing, and resizing through making new memory associations

      sliding_window_2 = klass.new('TestSlidingWindow', 4, 0660)
      sliding_window_2 << 80 << 90 << 100 << 110 << 120
      assert_correct_first_and_last_and_size(@sliding_window, 90, 120, 4, 4)
      assert_sliding_windows_in_sync(@sliding_window, sliding_window_2)

      sliding_window_2 = klass.new('TestSlidingWindow', 3, 0660)
      assert_sliding_windows_in_sync(@sliding_window, sliding_window_2)
      assert_correct_first_and_last_and_size(@sliding_window, 100, 120, 3, 3)

      @sliding_window.resize_to(2)
      assert_sliding_windows_in_sync(@sliding_window, sliding_window_2)
      assert_correct_first_and_last_and_size(@sliding_window, 110, 120, 2, 2)

      sliding_window_2 = klass.new('TestSlidingWindow', 4, 0660)
      assert_sliding_windows_in_sync(@sliding_window, sliding_window_2)
      assert_correct_first_and_last_and_size(@sliding_window, 110, 120, 2, 4)

      @sliding_window.resize_to(6)
      @sliding_window << 130
      assert_sliding_windows_in_sync(@sliding_window, sliding_window_2)
      assert_correct_first_and_last_and_size(@sliding_window, 110, 130, 3, 6)

      sliding_window_2 = klass.new('TestSlidingWindow', 2, 0660)
      assert_sliding_windows_in_sync(@sliding_window, sliding_window_2)
      assert_correct_first_and_last_and_size(@sliding_window, 120, 130, 2, 2)

      @sliding_window.resize_to(4)
      assert_sliding_windows_in_sync(@sliding_window, sliding_window_2)
      assert_correct_first_and_last_and_size(@sliding_window, 120, 130, 2, 4)

      sliding_window_2 = klass.new('TestSlidingWindow', 6, 0660)
      assert_sliding_windows_in_sync(@sliding_window, sliding_window_2)
      assert_correct_first_and_last_and_size(@sliding_window, 120, 130, 2, 6)

      sliding_window_2.clear
    end
  end

  def teardown
    @sliding_window.destroy
  end

  private

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

  def run_test_once_with_sysv_and_once_without_sysv_to_assert_correctness
    yield(Semian::SysVSlidingWindow)
    teardown
    # Use fake class backed by lookup table by name to make sure results are correct
    @sliding_window = FakeSysVSlidingWindow.new('TestSlidingWindow', 6, 0660)
    yield(FakeSysVSlidingWindow)
  end
end
