require 'test_helper'

class TestSimpleEnum < MiniTest::Unit::TestCase
  CLASS = ::Semian::Simple::Enum

  def setup
    @enum = CLASS.new([:one, :two, :three])
  end

  def teardown
    @enum.destroy
  end

  module EnumTestCases
    def test_assigning
      old = @enum.value
      @enum.value = @enum.value
      assert_equal old, @enum.value
      @enum.value = :two
      assert_equal :two, @enum.value
    end

    def test_iterate_enum
      @enum.value = :one
      @enum.increment
      assert_equal :two, @enum.value
      @enum.increment
      assert_equal :three, @enum.value
      @enum.increment
      assert_equal :one, @enum.value
      @enum.increment(2)
      assert_equal :three, @enum.value
      @enum.increment(4)
      assert_equal :one, @enum.value
      @enum.increment(0)
      assert_equal :one, @enum.value
    end

    def test_will_throw_error_when_invalid_symbol_given
      assert_raises KeyError do
        @enum.value = :four
      end
    end
  end

  include EnumTestCases
end
