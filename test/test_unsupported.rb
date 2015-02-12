require 'minitest/autorun'
require 'semian'

class TestSemian < MiniTest::Unit::TestCase
  def setup
    Semian.destroy(:testing) rescue nil
  end

  def test_unsupported_acquire_yields
    acquired = false
    Semian.register :testing, tickets: 1
    Semian[:testing].acquire { acquired = true }
    assert acquired
  end

  def test_unsuported_constants
    assert defined?(Semian::BaseError)
    assert defined?(Semian::SyscallError)
    assert defined?(Semian::TimeoutError)
    assert defined?(Semian::InternalError)
    assert defined?(Semian::Resource)
  end
end
