require 'test_helper'

class TestSysVInteger < MiniTest::Unit::TestCase
  CLASS = ::Semian::SysV::Integer

  def setup
    @integer = CLASS.new(name: 'TestSysVInteger', permissions: 0660)
    @integer.reset
  end

  def teardown
    @integer.destroy
  end

  include TestSimpleInteger::IntegerTestCases

  def test_memory_is_shared
    integer_2 = CLASS.new(name: 'TestSysVInteger', permissions: 0660)
    integer_2.value = 100
    assert_equal 100, @integer.value
    @integer.value = 200
    assert_equal 200, integer_2.value
    @integer.value = 0
    assert_equal 0, integer_2.value
  end

  def test_memory_not_reset_when_at_least_one_worker_using_it
    @integer.value = 109
    integer_2 = CLASS.new(name: 'TestSysVInteger', permissions: 0660)
    assert_equal @integer.value, integer_2.value

    reader, writer = IO.pipe
    pid = fork do
      reader.close
      integer_3 = CLASS.new(name: 'TestSysVInteger', permissions: 0660)
      assert_equal 109, integer_3.value
      integer_3.value = 110
      writer.puts "Done"
      writer.close
      sleep
    end

    reader.gets
    Process.kill(9, pid)
    assert_equal 110, integer_2.value
  end

  def test_memory_reset_when_no_workers_using_it
    fork do
      integer = CLASS.new(name: 'TestSysVInteger_2', permissions: 0660)
      integer.value = 109
    end
    Process.waitall
    @integer = CLASS.new(name: 'TestSysVInteger_2', permissions: 0660)
    assert_equal 0, @integer.value
  end
end
