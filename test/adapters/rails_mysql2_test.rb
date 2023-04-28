# frozen_string_literal: true

require "test_helper"
require_relative "rails_tests"
require "semian/mysql2"

class TestRailsMysql2 < Minitest::Test
  include RailsTests

  def setup
    @adapter = "mysql2"
    super
  end
end
