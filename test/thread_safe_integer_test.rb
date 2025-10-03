# frozen_string_literal: true

require "test_helper"

class TestThreadSafeInteger < Minitest::Test
  def setup
    @integer = ::Semian::ThreadSafe::Integer.new
  end

  def teardown
    @integer.destroy
  end

  module IntegerTestCases
    def test_access_value
      assert_equal(0, @integer.value)
      @integer.value = 99

      assert_equal(99, @integer.value)
      time_now = Time.now.to_i
      @integer.value = time_now

      assert_equal(time_now, @integer.value)
      @integer.value = 6

      assert_equal(6, @integer.value)
      @integer.value = 6

      assert_equal(6, @integer.value)
    end

    def test_increment
      @integer.increment(4)

      assert_equal(4, @integer.value)
      @integer.increment

      assert_equal(5, @integer.value)
      @integer.increment(-2)

      assert_equal(3, @integer.value)
    end

    def test_reset_on_init
      assert_equal(0, @integer.value)
    end

    def test_reset
      @integer.increment(5)
      @integer.reset

      assert_equal(0, @integer.value)
    end

    def test_concurrent_increment_and_access
      threads = []
      thread_count = 5
      values_read = Concurrent::Array.new

      thread_count.times do |_i|
        threads << Thread.new do
          @integer.increment(1)
          current_value = @integer.value
          values_read << current_value
        end
      end

      threads.each(&:join)

      assert_equal(thread_count, @integer.value)
      assert_equal(thread_count, values_read.size)

      values_read.each do |value|
        assert_operator(value, :>=, 1, "Read value #{value} should be at least 1")
        assert_operator(value, :<=, thread_count, "Read value #{value} should be at most #{thread_count}")
      end
    end

    def test_concurrent_reset
      threads = []

      assert_equal(0, @integer.value, "Integer should be initialized to 0")

      4.times do
        threads << Thread.new do
          10.times { @integer.increment(1) }
        end
      end

      threads << Thread.new do
        @integer.reset
      end

      threads.each(&:join)

      assert_equal(0, @integer.value, "Integer should be 0 after reset")

      @integer.increment(5)

      assert_equal(5, @integer.value, "Integer should work normally after reset")
    end
  end

  include IntegerTestCases
end
