require 'test_helper'

class TestSysVAtomicEnum < MiniTest::Unit::TestCase
  # Emulate sharedness to test correctness against real SysVAtomicEnum class
  class FakeSysVAtomicEnum < Semian::AtomicEnum
    class << self
      attr_accessor :resources
    end
    self.resources = {}
    attr_accessor :name
    def self.new(name, _permissions, _symbol_list)
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
    run_test_with_atomic_enum_classes do |klass|
      assert_equal :one, @enum.value
      @enum.value = :three

      enum_2 = klass.new('TestAtomicEnum', 0660, [:one, :two, :three])
      assert_equal :three, enum_2.value
    end
  end

  private

  def atomic_enum_classes
    @classes ||= [::Semian::SysVAtomicEnum, FakeSysVAtomicEnum]
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
