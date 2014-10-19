require 'test/unit'
require 'semian'

class TestSemian < Test::Unit::TestCase
  def test_unsupported_acquire_yields
    acquired = false
    Semian.register :testing, tickets: 1
    Semian[:testing].acquire { acquired = true }
    assert acquired
  end
end
