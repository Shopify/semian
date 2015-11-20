require 'test_helper'

class TestSysVState < MiniTest::Unit::TestCase
  KLASS = ::Semian::SysV::State

  def setup
    @state = KLASS.new(name: 'TestSysVState',
                       permissions: 0660)
    @state.reset
  end

  def teardown
    @state.destroy
  end

  include TestSimpleState::StateTestCases

  def test_memory_is_shared
    assert_equal :closed, @state.value
    @state.open

    state_2 = KLASS.new(name: 'TestSysVState',
                        permissions: 0660)
    assert_equal :open, state_2.value
    assert state_2.open?
  end

  def test_will_throw_error_when_invalid_symbol_given
    # May occur if underlying integer gets into bad state
    integer = @state.instance_eval "@integer"
    integer.value = 100
    assert_raises ArgumentError do
      @state.value
    end
    assert_raises ArgumentError do
      @state.open?
    end
    assert_raises ArgumentError do
      @state.half_open?
    end
    assert_raises ArgumentError do
      @state.closed?
    end
  end
end
