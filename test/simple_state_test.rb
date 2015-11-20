require 'test_helper'

class TestSimpleState < MiniTest::Unit::TestCase
  KLASS = ::Semian::Simple::State

  def setup
    @state = KLASS.new
  end

  def teardown
    @state.destroy
  end

  module StateTestCases
    def test_start_closed?
      assert @state.closed?
    end

    def test_open
      @state.open
      assert @state.open?
      assert_equal @state.value, :open
    end

    def test_close
      @state.close
      assert @state.closed?
      assert_equal @state.value, :closed
    end

    def test_half_open
      @state.half_open
      assert @state.half_open?
      assert_equal @state.value, :half_open
    end

    def test_reset
      @state.reset
      assert @state.closed?
      assert_equal @state.value, :closed
    end
  end

  include StateTestCases
end
