require 'test_helper'

class TestAtomicEnum < MiniTest::Unit::TestCase
  def test_assigning
    run_test_with_atomic_enum_classes do
      old = @enum.value
      @enum.value = @enum.value
      assert_equal old, @enum.value
      @enum.value = :two
      assert_equal :two, @enum.value
    end
  end

  def test_iterate_enum
    run_test_with_atomic_enum_classes do
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
  end

  def test_will_throw_error_when_invalid_symbol_given
    run_test_with_atomic_enum_classes do
      assert_raises KeyError do
        @enum.value = :four
      end
    end
  end

  private

  def atomic_enum_classes
    @classes ||= [::Semian::AtomicEnum]
  end

  def run_test_with_atomic_enum_classes(klasses = atomic_enum_classes)
    klasses.each do |klass|
      begin
        @enum = klass.new([:one, :two, :three],
                          name: 'TestAtomicEnum',
                          permissions: 0660)
        yield(klass)
      ensure
        @enum.destroy
      end
    end
  end
end
