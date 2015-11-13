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

  private

  include TestSimpleSlidingWindow::SlidingWindowUtilityMethods
end
