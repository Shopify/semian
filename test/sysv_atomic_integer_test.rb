require 'test_helper'

class TestSysVAtomicInteger < MiniTest::Unit::TestCase
  # Emulate sharedness to test correctness against real SysVAtomicInteger class
  class FakeSysVAtomicInteger < Semian::AtomicInteger
    class << self
      attr_accessor :resources
    end
    self.resources = {}
    attr_accessor :name
    def self.new(name, _permissions)
      obj = resources[name] ||= super
      obj.name = name
      obj
    end

    def destroy
      self.class.resources.delete(@name)
      super
    end

    def shared?
      true
    end
  end

  def test_memory_is_shared
    run_test_with_atomic_integer_classes do |klass|
      integer_2 = klass.new('TestAtomicInteger', 0660)
      integer_2.value = 100
      assert_equal 100, @integer.value
      @integer.value = 200
      assert_equal 200, integer_2.value
      @integer.value = 0
      assert_equal 0, integer_2.value
    end
  end

  def test_memory_not_reset_when_at_least_one_worker_using_it
    run_test_with_atomic_integer_classes do |klass|
      @integer.value = 109
      integer_2 = klass.new('TestAtomicInteger', 0660)
      assert_equal @integer.value, integer_2.value
      pid = fork do
        integer_3 = klass.new('TestAtomicInteger', 0660)
        assert_equal 109, integer_3.value
        sleep
      end
      sleep 1
      Process.kill("KILL", pid)
      Process.waitall
      fork do
        integer_3 = klass.new('TestAtomicInteger', 0660)
        assert_equal 109, integer_3.value
      end
      Process.waitall
    end
  end

  private

  def atomic_integer_classes
    @classes ||= [::Semian::SysVAtomicInteger, FakeSysVAtomicInteger]
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
