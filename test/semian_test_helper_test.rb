require 'test_helper'
require 'semian/test_helpers'

class TestTestHelpers < Minitest::Test
  include Semian::TestHelpers

  def setup
    Semian.register(:testing,
                    tickets: 1,
                    exceptions: [Semian::TestHelpers::Error],
                    error_threshold: 3,
                    error_timeout: 5,
                    success_threshold: 1,
                   )

    @resource = Semian[:testing]
  end

  def test_open_circuit_will_open_circuit
    open_circuit!(@resource)
    assert_circuit_opened(@resource)
  end

  def test_trigger_error_will_open_circuit
    3.times { trigger_error!(@resource) }
    assert_circuit_opened(@resource)
  end

  def test_circuit_closed_by_default
    assert_circuit_closed(@resource)
  end

  def test_half_open_circuit
    half_open_cicuit!(@resource)
    assert_circuit_opened(@resource)
  end
end
