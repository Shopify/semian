module CircuitBreakerHelper
  SomeError = Class.new(StandardError)

  private

  def open_circuit!(resource = @resource, error_count = 2, elapsed_time = nil)
    if elapsed_time == nil
      error_count.times { trigger_error!(resource) }
    else
      error_count.times { trigger_error_elapse_time!(resource, elapsed_time) }
    end
  end

  def half_open_cicuit!(resource = @resource, backwards_time_travel = 10)
    Timecop.travel(Time.now - backwards_time_travel) do
      open_circuit!(resource)
    end
  end

  def trigger_error!(resource = @resource, error = SomeError)
    resource.acquire { raise error, "some error message" }
  rescue error
  end

  def trigger_error_elapse_time!(resource = @resource, error = SomeError, elapsed_time)
    Timecop.travel(-1 * elapsed_time) do
      begin
        resource.acquire {
          Timecop.return_to_baseline
          raise error
        }
      rescue error
      end
    end
  end

  def assert_circuit_closed_elapse_time(resource = @resource, elapsed_time)
    block_called = false
    Timecop.travel(-1 * elapsed_time) do
      resource.acquire do
        Timecop.return_to_baseline
        block_called = true
      end
    end
    assert block_called, 'Expected the circuit to be closed, but it was open'
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
