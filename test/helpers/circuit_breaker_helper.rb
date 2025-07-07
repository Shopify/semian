# frozen_string_literal: true

module CircuitBreakerHelper
  SomeError = Class.new(StandardError)

  private

  def open_circuit!(resource = @resource, error_count = 2)
    error_count.times { trigger_error!(resource) }
  end

  def half_open_cicuit!(resource = @resource, backwards_time_travel = 10)
    time_travel(-backwards_time_travel) do
      open_circuit!(resource)
    end
  end

  def trigger_error!(resource = @resource, error = SomeError)
    resource.acquire { raise error, "some error message" }
  rescue error
  end

  def assert_circuit_closed(resource = @resource)
    block_called = false

    circuit_breaker = resource.circuit_breaker

    old_errors = create_sliding_window_copy(circuit_breaker.instance_variable_get(:@errors))
    previously_open = circuit_breaker&.send(:open?)
    previously_half_open = circuit_breaker&.send(:half_open?)

    resource.acquire { block_called = true }

    now_closed = !circuit_breaker&.send(:open?)

    unless previously_half_open || previously_open && now_closed || circuit_breaker.instance_variable_get(:@error_threshold_timeout_enabled).nil? || circuit_breaker.instance_variable_get(:@error_threshold_timeout_enabled)
      circuit_breaker.instance_variable_set(:@errors, old_errors)
    end

    assert(block_called, "Expected the circuit to be closed, but it was open")
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

  def create_sliding_window_copy(sliding_window)
    return if sliding_window.nil?

    implementation_class = sliding_window.class

    new_window = implementation_class.new(max_size: sliding_window.max_size)

    if sliding_window.respond_to?(:size) && !sliding_window.empty?
      original_data = sliding_window.instance_variable_get(:@window)
      if original_data.is_a?(Array)
        new_window.instance_variable_set(:@window, original_data.dup)
      end
    end

    new_window
  end
end
