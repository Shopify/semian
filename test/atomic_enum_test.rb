require 'test_helper'

class TestAtomicEnum < MiniTest::Unit::TestCase
  def test_functionality
    run_test_with_atomic_enum_classes do
      @enum.value = :two
      assert_equal :two, @enum.value
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
    @classes ||= retrieve_descendants(::Semian::AtomicEnum)
  end

  def run_test_with_atomic_enum_classes(klasses = atomic_enum_classes)
    klasses.each do |klass|
      begin
        @enum = klass.new('TestAtomicEnum', 0660, [:one, :two, :three])
        yield(klass)
      ensure
        @enum.destroy
      end
    end
  end
end
