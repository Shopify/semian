require 'test_helper'

class TestInstrumentation < Minitest::Test
  def setup
    Semian.destroy(:testing) if Semian[:testing]
    Semian.register(:testing, tickets: 1, error_threshold: 1, error_timeout: 5, success_threshold: 1)
  end

  def test_busy_instrumentation
    assert_notify(:success, :busy) do
      Semian[:testing].acquire do
        assert_raises Semian::TimeoutError do
          Semian[:testing].acquire {}
        end
      end
    end
  end

  def test_circuit_open_instrumentation
    assert_notify(:success, :busy) do
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

  def test_success_instrumentation_wait_time
    hit = false
    subscription = Semian.subscribe do |*_, wait_time:|
      hit = true
      assert(wait_time.is_a?(Integer))
    end
    Semian[:testing].acquire {}
    assert(hit)
  ensure
    Semian.unsubscribe(subscription)
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
    subscription = Semian.subscribe do |event, _resource|
      events << event
    end
    yield
    assert_equal expected_events, events, "The timeline of events was not as expected"
  ensure
    Semian.unsubscribe(subscription)
  end
end
