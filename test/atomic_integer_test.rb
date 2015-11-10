require 'test_helper'

class TestAtomicInteger < MiniTest::Unit::TestCase
  CLASS = ::Semian::AtomicInteger

  def setup
    @integer = CLASS.new(name: 'TestAtomicInteger', permissions: 0660)
    @integer.value = 0
  end

  def teardown
    @integer.destroy
  end

  module AtomicIntegerTestCases
    def test_access_value
      @integer.value = 0
      assert_equal(0, @integer.value)
      @integer.value = 99
      assert_equal(99, @integer.value)
      time_now = (Time.now).to_i
      @integer.value = time_now
      assert_equal(time_now, @integer.value)
      @integer.value = 6
      assert_equal(6, @integer.value)
      @integer.value = 6
      assert_equal(6, @integer.value)
    end

    def test_increment
      @integer.value = 0
      @integer.increment(4)
      assert_equal(4, @integer.value)
      @integer.increment
      assert_equal(5, @integer.value)
      @integer.increment(-2)
      assert_equal(3, @integer.value)
    end
  end

  include AtomicIntegerTestCases
end
