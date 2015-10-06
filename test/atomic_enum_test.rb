require 'test_helper'

class TestAtomicEnum < MiniTest::Unit::TestCase
  def setup

    @enum = Semian::AtomicEnum.new("TestAtomicEnum",0660, [:one, :two, :three])
  end

  def test_memory_is_shared
    return if !Semian::AtomicEnum.shared?
    assert_equal :one,@enum.value
    @enum.value= :three

    enum_2 = Semian::AtomicEnum.new("TestAtomicEnum",0660, [:one, :two, :three])
    assert_equal :three,enum_2.value
  end

  def test_will_throw_error_when_invalid_symbol_given
    assert_raises KeyError do
      @enum.value = :four
    end
  end

  def teardown
    @enum.destroy
  end

end
