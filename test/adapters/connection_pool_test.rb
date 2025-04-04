# frozen_string_literal: true

require "test_helper"
require "semian/connection_pool"

class TestConnectionPool < Minitest::Test
  def test_with_semian_resource
    pool = ConnectionPool.new(
      size: 1,
      timeout: 0,
      semian_resource: Semian::Resource.new("blah"),
    ) do
      Object.new
    end

    refute_nil(pool.semian_resource)
    assert_equal("blah", pool.semian_resource.name)
  end
end
