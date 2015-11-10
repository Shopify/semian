require 'test_helper'

class TestSysVAtomicEnum < MiniTest::Unit::TestCase
  # Emulate sharedness to test correctness against real SysVAtomicEnum class
  class FakeSysVAtomicEnum < Semian::AtomicEnum
    class << self
      attr_accessor :resources
    end
    self.resources = {}
    attr_accessor :name
    def self.new(symbol_list, name:, permissions:)
      obj = resources[name] ||= super
      obj.name = name
      obj
    end

    def destroy
      self.class.resources.delete(@name)
    end

    def shared?
      true
    end
  end

  CLASS = ::Semian::SysVAtomicEnum

  def setup
    @enum = CLASS.new([:one, :two, :three],
                      name: 'TestAtomicEnum',
                      permissions: 0660)
  end

  def teardown
    @enum.destroy
  end

  include TestAtomicEnum::AtomicEnumTestCases

  def test_memory_is_shared
    assert_equal :one, @enum.value
    @enum.value = :three

    enum_2 = CLASS.new([:one, :two, :three],
                       name: 'TestAtomicEnum',
                       permissions: 0660)
    assert_equal :three, enum_2.value
  end
end
