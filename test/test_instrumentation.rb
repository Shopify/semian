require 'minitest/autorun'
require 'semian'

class TestInstrumentation < MiniTest::Unit::TestCase
  def setup
    Semian.destroy(:testing) if Semian[:testing]
    Semian.register(:testing, tickets: 1, error_threshold: 1)
  end

  def test_occupied_instrumentation
    assert_notify(:success, :occupied) do
      Semian[:testing].acquire do
        assert_raises Semian::TimeoutError do
          Semian[:testing].acquire {}
        end
      end
    end
  end

  def test_circuit_open_instrumentation
    assert_notify(:success, :occupied) do
      Semian[:testing].acquire do
        assert_raises Semian::TimeoutError do
          Semian[:testing].acquire {}
        end
      end
    end

    assert_notify(:circuit_open) do
      assert_raises Semian::OpenCircuitError do
        Semian[:testing].acquire {}
      end
    end
  end

  def test_success_instrumentation
    assert_notify(:success) do
      Semian[:testing].acquire {}
    end
  end

  def test_success_instrumentation_when_unknown_exceptions_occur
    assert_notify(:success) do
      assert_raises RuntimeError do
        Semian[:testing].acquire { raise "Some error" }
      end
    end
  end

  private

  def assert_notify(*expected_events)
    events = []
    subscription = Semian.subscribe do |event, resource|
      events << event
    end
    yield
    assert_equal expected_events, events, "The timeline of events was not as expected"
  ensure
    Semian.unsubscribe(subscription)
  end
end
