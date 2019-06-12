require 'test_helper'

class TestSimpleEnum < Minitest::Test
  def setup
    state_val = ::Semian::ThreadSafe::Integer.new(:test_simple_enum)
    @state = ::Semian::ThreadSafe::State.new(state_val)
  end

  def teardown
    @state.destroy
  end

  module StateTestCases
    def test_start_closed?
      assert @state.closed?
    end

    def test_open
      @state.open!
      assert @state.open?
      assert_equal ::Semian::Simple::State::OPEN, @state.value
    end

    def test_close
      @state.close!
      assert @state.closed?
      assert_equal ::Semian::Simple::State::CLOSED, @state.value
    end

    def test_half_open
      @state.half_open!
      assert @state.half_open?
      assert_equal ::Semian::Simple::State::HALF_OPEN, @state.value
    end

    def test_reset
      @state.reset
      assert @state.closed?
      assert_equal ::Semian::Simple::State::CLOSED, @state.value
    end
  end

  include StateTestCases
end
