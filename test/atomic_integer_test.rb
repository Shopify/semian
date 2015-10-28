require 'test_helper'

class TestAtomicInteger < MiniTest::Unit::TestCase
  def test_operations
    run_test_with_atomic_integer_classes do
      @integer.value = 0
      @integer.increment_by(4)
      assert_equal(4, @integer.value)
      @integer.increment
      assert_equal(5, @integer.value)
      @integer.value = 10
      assert_equal(10, @integer.value)
    end
  end

  def test_execute_atomically_actually_is_atomic
    run_test_with_atomic_integer_classes do |klass|
      Timeout.timeout(1) do # assure dont hang
        @integer.value = 100
        assert_equal 100, @integer.value
      end
      pids = []
      5.times do
        pids << fork do
          integer_2 = klass.new('TestAtomicInteger', 0660)
          integer_2.execute_atomically do
            integer_2.value += 1
            sleep 1
          end
        end
      end
      sleep 1
      pids.each { |pid| Process.kill('KILL', pid) }
      assert @integer.value < 105

      Process.waitall
    end
  end

  private

  def atomic_integer_classes
    @classes ||= retrieve_descendants(::Semian::AtomicInteger).select { |klass| /Integer/.match(klass.name) }
  end

  def run_test_with_atomic_integer_classes(klasses = atomic_integer_classes)
    klasses.each do |klass|
      begin
        @integer = klass.new('TestAtomicInteger', 0660)
        @integer.value = 0
        yield(klass)
      ensure
        @integer.destroy
      end
    end
  end
end
