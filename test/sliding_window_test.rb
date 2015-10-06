require 'test_helper'

class TestSlidingWindow < MiniTest::Unit::TestCase
  def setup
    @sliding_window = Semian::SlidingWindow.new("TestSlidingWindow",6,0660)
    @sliding_window.clear
  end

  def test_forcefully_killing_worker_holding_on_to_semaphore_releases_it
    Timeout::timeout(1) do #assure dont hang
      @sliding_window<<100
      assert_equal 100,@sliding_window.first
    end

    pid = fork {
      sliding_window_2 = Semian::SlidingWindow.new("TestSlidingWindow",6,0660)
      sliding_window_2.execute_atomically {
        sleep
      }
    }

    sleep 1
    Process.kill("KILL", pid)
    Process.waitall

    Timeout::timeout(1) do #assure dont hang
      @sliding_window<<100
      assert_equal 100,@sliding_window.first
    end

  end

  def test_sliding_window_memory_is_actually_shared
    return if !Semian::SlidingWindow.shared?

    assert_equal 0, @sliding_window.size
    sliding_window_2 = Semian::SlidingWindow.new("TestSlidingWindow",6,0660)
    assert_equal 0, sliding_window_2.size

    large_number = (Time.now.to_f*1000).to_i
    @sliding_window << large_number
    assert_equal large_number, @sliding_window.first
    assert_equal large_number, sliding_window_2.first
    assert_equal large_number, @sliding_window.last
    assert_equal large_number, sliding_window_2.last
    sliding_window_2<<6<<4<<3<<2
    assert_equal 2, @sliding_window.last
    assert_equal 2, sliding_window_2.last
    assert_equal 5, @sliding_window.size

    @sliding_window.clear
    assert_equal 0, @sliding_window.size
    assert_equal 0, sliding_window_2.size
  end

  def test_sliding_window_edge_falloff

    assert_equal 0, @sliding_window.size

    @sliding_window <<1<<2<<3<<4<<5<<6<<7
    assert_equal 6, @sliding_window.size
    assert_equal 2, @sliding_window.first
    assert_equal 7, @sliding_window.last

    @sliding_window.shift
    assert_equal 3, @sliding_window.first
    assert_equal 7, @sliding_window.last
    @sliding_window.clear
  end

  def test_restarting_worker_should_not_reset_queue
    return if !Semian::SlidingWindow.shared?
    @sliding_window <<10<<20<<30
    sliding_window_2 = Semian::SlidingWindow.new("TestSlidingWindow", 6, 0660)
    assert_equal 3, @sliding_window.size
    assert_equal 10, @sliding_window.first
    sliding_window_2.pop
    assert_equal 20, @sliding_window.last

    sliding_window_3 = Semian::SlidingWindow.new("TestSlidingWindow", 6, 0660)
    assert_equal 2, @sliding_window.size
    assert_equal 10, @sliding_window.first
    assert_equal 20, @sliding_window.last
    sliding_window_3.pop
    assert_equal 1, @sliding_window.size
    assert_equal 10, @sliding_window.last
    assert_equal 10, sliding_window_2.last
    @sliding_window.clear
  end

  def test_other_workers_automatically_switching_to_new_memory_resizing_up_or_down
    return if !Semian::SlidingWindow.shared?
    # Test explicit resizing, and resizing through making new memory associations

    sliding_window_2 = Semian::SlidingWindow.new("TestSlidingWindow", 4, 0660)
    sliding_window_2<<80<<90<<100<<110<<120
    assert_equal 4, @sliding_window.max_size
    assert_equal 4, @sliding_window.size
    assert_equal 4, sliding_window_2.max_size
    assert_equal 4, sliding_window_2.size
    assert_equal 90, @sliding_window.first
    assert_equal 120, @sliding_window.last

    sliding_window_2 = Semian::SlidingWindow.new("TestSlidingWindow", 3, 0660)
    assert_equal 100, @sliding_window.first
    assert_equal 120, @sliding_window.last
    assert_equal 100, sliding_window_2.first
    assert_equal 120, sliding_window_2.last

    @sliding_window.resize_to 2
    assert_equal 110, @sliding_window.first
    assert_equal 120, @sliding_window.last
    assert_equal 110, sliding_window_2.first
    assert_equal 120, sliding_window_2.last

    sliding_window_2 = Semian::SlidingWindow.new("TestSlidingWindow", 4, 0660)
    assert_equal 4, @sliding_window.max_size
    assert_equal 4, sliding_window_2.max_size
    assert_equal 2, @sliding_window.size
    assert_equal 2, sliding_window_2.size

    @sliding_window.resize_to 6
    assert_equal 6, @sliding_window.max_size
    assert_equal 2, @sliding_window.size
    assert_equal 110, @sliding_window.first
    assert_equal 120, @sliding_window.last
    assert_equal 110, sliding_window_2.first
    assert_equal 120, sliding_window_2.last

    sliding_window_2 = Semian::SlidingWindow.new("TestSlidingWindow", 2, 0660)
    assert_equal 110, @sliding_window.first
    assert_equal 120, @sliding_window.last
    assert_equal 110, sliding_window_2.first
    assert_equal 120, sliding_window_2.last

    @sliding_window.resize_to 4
    assert_equal 4, @sliding_window.max_size
    assert_equal 4, sliding_window_2.max_size
    assert_equal 2, @sliding_window.size
    assert_equal 2, sliding_window_2.size

    sliding_window_2 = Semian::SlidingWindow.new("TestSlidingWindow", 6, 0660)
    assert_equal 6, @sliding_window.max_size
    assert_equal 2, @sliding_window.size
    assert_equal 110, @sliding_window.first
    assert_equal 120, @sliding_window.last
    assert_equal 110, sliding_window_2.first
    assert_equal 120, sliding_window_2.last

    sliding_window_2.clear
  end

  def teardown
    @sliding_window.destroy
  end

end
