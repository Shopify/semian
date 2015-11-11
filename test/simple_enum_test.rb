require 'test_helper'

class TestSimpleEnum < MiniTest::Unit::TestCase
  CLASS = ::Semian::Simple::Enum

  def setup
    @enum = CLASS.new
  end

  def teardown
    @enum.destroy
  end

  module EnumTestCases

    def test_start_closed
      assert @enum.closed?
    end

    def test_open
      @enum.open
      assert @enum.open?
    end

    def test_half_open
      @enum.half_open
      assert @enum.half_open?
    end

    def test_close
      @enum.half_open
      @enum.close
      assert @enum.closed?
    end
  end

  include EnumTestCases
end
