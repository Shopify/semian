# frozen_string_literal: true

require "test_helper"

class TestNonThreadSafeInteger < Minitest::Test
  def setup
    @integer = ::Semian::Simple::Integer.new # Using non-thread-safe implementation
  end

  def teardown
    @integer.destroy
  end

  # The concurrent test that should expose race conditions
  # Race condition:
  # Thread A calls increment(1)
  # Thread B calls @atom.value = 0
  # Thread A's increment can complete after the assignment, overwriting the reset
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
