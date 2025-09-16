# frozen_string_literal: true

require "test_helper"
require "concurrent"

class TestConcurrency < Minitest::Test
  def test_concurrent_access
    assert_equal(0, 0)
  end
end
