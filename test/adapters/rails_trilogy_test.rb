# frozen_string_literal: true

require "test_helper"
require_relative "rails_tests"
require "semian/activerecord_trilogy_adapter"

class TestRailsTrilogy < Minitest::Test
  include RailsTests

  def setup
    @adapter = "trilogy"
    super
  end
end
