module CircuitBreakerHelper
  SomeError = Class.new(StandardError)

  private

  def open_circuit!(resource = @resource, error_count = 2)
    error_count.times { trigger_error!(resource) }
  end

  def half_open_cicuit!(resource = @resource, backwards_time_travel = 10)
    Timecop.travel(Time.now - backwards_time_travel) do
      open_circuit!(resource)
    end
  end

  def trigger_error!(resource = @resource, error = SomeError)
    resource.acquire do
      raise error
    end
  rescue error
  end

  def assert_circuit_closed(resource = @resource)
    block_called = false
    resource.acquire { block_called = true }
    assert block_called, 'Expected the circuit to be closed, but it was open'
  end

  def assert_circuit_opened(resource = @resource)
    open = false
    begin
      resource.acquire {}
    rescue Semian::OpenCircuitError
      open = true
    end
    assert open, 'Expected the circuit to be open, but it was closed'
  end
end
