# frozen_string_literal: true

require "test_helper"

class TestSimpleEnum < Minitest::Test
  def setup
    @state = ::Semian::ThreadSafe::State.new
  end

  def teardown
    @state.destroy
  end

  module StateTestCases
    def test_start_closed?
      assert_predicate(@state, :closed?)
    end

    def test_open
      @state.open!

      assert_predicate(@state, :open?)
      assert_equal(:open, @state.value)
    end

    def test_close
      @state.close!

      assert_predicate(@state, :closed?)
      assert_equal(:closed, @state.value)
    end

    def test_half_open
      @state.half_open!

      assert_predicate(@state, :half_open?)
      assert_equal(:half_open, @state.value)
    end

    def test_reset
      @state.reset

      assert_predicate(@state, :closed?)
      assert_equal(:closed, @state.value)
    end
  end

  include StateTestCases
end
