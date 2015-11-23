require 'test_helper'

class TestSysVInteger < MiniTest::Unit::TestCase
  KLASS = ::Semian::SysV::Integer

  def setup
    @integer = KLASS.new(name: 'TestSysVInteger', permissions: 0660)
    @integer.reset
  end

  def teardown
    @integer.destroy
  end

  include TestSimpleInteger::IntegerTestCases
end
