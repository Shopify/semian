# frozen_string_literal: true

module CircuitBreakerHelper
  SomeError = Class.new(StandardError)

  def open_circuit!(resource = @resource, error_count: 2)
    error_count.times { trigger_error!(resource) }
  end

  def half_open_cicuit!(resource = @resource, error_count: 2, backwards_time_travel: 10)
    time_travel(-backwards_time_travel) do
      open_circuit!(resource, error_count: error_count)
    end
  end

  def trigger_error!(resource = @resource, error: SomeError)
    resource.acquire { raise error, "some error message" }
  rescue error
  end

  def assert_circuit_closed(resource = @resource)
    acquired = false
    resource.acquire { acquired = true }

    assert(acquired, "Expected the circuit to be closed, but it was open")
  end

  def assert_circuit_opened(resource = @resource)
    open = false
    begin
      resource.acquire {}
    rescue Semian::OpenCircuitError
      open = true
    end

    assert(open, "Expected the circuit to be open, but it was closed")
  end

  def assert_log_message_match(pattern, level: :debug, &block)
    old = Semian.logger
    subject = StringIO.new
    Semian.logger = Logger.new(subject, level)
    yield

    assert_match(pattern, subject.string)
  ensure
    Semian.logger = old
  end
end
