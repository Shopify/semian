begin
  require 'minitest/test'
  test_class = Minitest::Test
rescue LoadError
  require "minitest/unit"
  test_class = MiniTest::Unit::TestCase
end

require 'semian'

test_class.class_eval do
  def teardown
    super
    Semian.unregister_all_resources
  end
end
