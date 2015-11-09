require 'test_helper'

class TestAtomicInteger < MiniTest::Unit::TestCase
  def test_access_value
    run_test_with_atomic_integer_classes do
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
  end

  def test_increment
    run_test_with_atomic_integer_classes do
      @integer.value = 0
      @integer.increment(4)
      assert_equal(4, @integer.value)
      @integer.increment
      assert_equal(5, @integer.value)
      @integer.increment(-2)
      assert_equal(3, @integer.value)
    end
  end

  private

  def atomic_integer_classes
    @classes ||= [::Semian::AtomicInteger]
  end

  def run_test_with_atomic_integer_classes(klasses = atomic_integer_classes)
    klasses.each do |klass|
      begin
        @integer = klass.new(name: 'TestAtomicInteger', permissions: 0660)
        @integer.value = 0
        yield(klass)
      ensure
        @integer.destroy
      end
    end
  end
end
