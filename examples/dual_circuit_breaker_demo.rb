#!/usr/bin/env ruby
# frozen_string_literal: true

require "bundler/setup"
require "semian"

# Example: Dual Circuit Breaker Demo
# This demonstrates how to use both legacy and adaptive circuit breakers
# simultaneously, switching between them at runtime based on a callable.

# Simulate a feature flag that can be toggled
class ExperimentFlags
  @enabled = false

  def enable_adaptive!
    @enabled = true
  end

  def disable_adaptive!
    @enabled = false
  end

  def use_adaptive_circuit_breaker?
    @enabled
  end
end

# Helper function to print state of all Semian objects between each phase
def print_semian_state
  puts "\n=== Semian Resources State ===\n"
  Semian.resources.values.each do |resource|
    puts "Resource: #{resource.name}"

    # Bulkhead info
    if resource.bulkhead
      puts "  Bulkhead: tickets=#{resource.tickets}, count=#{resource.count}"
    else
      puts "  Bulkhead: disabled"
    end

    # Circuit breaker info
    cb = resource.circuit_breaker
    if cb.nil?
      puts "  Circuit Breaker: disabled"
    elsif cb.is_a?(Semian::DualCircuitBreaker)
      puts "  Circuit Breaker: DualCircuitBreaker"
      metrics = cb.metrics
      puts "    Active: #{metrics[:active]}"
      puts "    Classic: state=#{metrics[:classic][:state]}, open=#{metrics[:classic][:open]}, half_open=#{metrics[:classic][:half_open]}"
      puts "    Adaptive: rejection_rate=#{metrics[:adaptive][:rejection_rate]}, error_rate=#{metrics[:adaptive][:error_rate]}"
    elsif cb.is_a?(Semian::AdaptiveCircuitBreaker)
      puts "  Circuit Breaker: AdaptiveCircuitBreaker"
      puts "    open=#{cb.open?}, closed=#{cb.closed?}, half_open=#{cb.half_open?}"
    else
      puts "  Circuit Breaker: Legacy"
      puts "    state=#{cb.state&.value}, open=#{cb.open?}, closed=#{cb.closed?}, half_open=#{cb.half_open?}"
      puts "    last_error=#{cb.last_error&.class}"
    end
    puts ""
  end
  puts "=== END STATE OUTPUT ===\n\n"
end

# Register a resource with dual circuit breaker mode
resource = Semian.register(
  :my_service,
  # Enable dual circuit breaker mode
  dual_circuit_breaker: true,

  # Legacy circuit breaker parameters (required)
  success_threshold: 2,
  error_threshold: 3,
  error_timeout: 10,

  # Adaptive circuit breaker parameters (optional, has defaults)
  seed_error_rate: 0.01,

  # Common parameters
  tickets: 5,
  timeout: 0.5,
  exceptions: [RuntimeError],
)

experiment_flags = ExperimentFlags.new
Semian::DualCircuitBreaker.adaptive_circuit_breaker_selector(->(_resource) { experiment_flags.use_adaptive_circuit_breaker? })

puts "=== Dual Circuit Breaker Demo ===\n\n"

# Helper to simulate service calls
def simulate_call(success: true)
  if success
    "Success!"
  else
    raise "Service error"
  end
end

# Test with legacy circuit breaker (use_adaptive returns false)
puts "Phase 1: Using LEGACY circuit breaker (use_adaptive=false)"
puts "The first 3 requests will succeed, the rest will fail."
puts "-" * 50

experiment_flags.disable_adaptive!

10.times do |i|
  result = Semian[:my_service].acquire do
    simulate_call(success: i < 3) # First 3 succeed, rest fail
  end
  puts "  Request #{i + 1}: #{result}"
rescue => e
  puts "  Request #{i + 1}: Failed - #{e.class.name}: #{e.message}"
end

print_semian_state

# Reset both circuit breakers
puts "\n" + "=" * 50
puts "Resetting circuit breakers..."
resource.circuit_breaker.reset

# Test with adaptive circuit breaker (use_adaptive returns true)
puts "\nPhase 2: Using ADAPTIVE circuit breaker (use_adaptive=true)"
puts "The first 3 requests will succeed, then the rest will be failures."
puts "The adaptive circuit breaker is not expected to open yet."
puts "-" * 50

experiment_flags.enable_adaptive!

# We use 300 requests so that the adaptive circuit breaker has at least 10 seconds to open
300.times do |i|
  begin
    result = Semian[:my_service].acquire do
      simulate_call(success: i < 3) # First 3 succeed, rest fail
    end
    puts "  Request #{i + 1}: #{result}"
  rescue => e
    puts "  Request #{i + 1}: Failed - #{e.class.name}: #{e.message}"
  end
  sleep 0.05 # Small delay to see adaptive behavior
end

print_semian_state

# Demonstrate dynamic switching
puts "\n" + "=" * 50
puts "Phase 3: Dynamic switching between circuit breakers"
puts "-" * 50

5.times do |i|
  # Toggle every 2 requests
  if i.even?
    experiment_flags.disable_adaptive!
    puts "  Switched to LEGACY"
  else
    experiment_flags.enable_adaptive!
    puts "  Switched to ADAPTIVE"
  end

  begin
    result = Semian[:my_service].acquire do
      simulate_call(success: true)
    end
    puts "    Request #{i + 1}: #{result}"
  rescue => e
    puts "    Request #{i + 1}: Failed - #{e.class.name}"
  end
end

puts "\n=== Demo Complete ===\n"
puts "Both circuit breakers tracked all requests, but only the active one"
puts "was used for decision-making based on the adaptive_circuit_breaker_selector callable."

print_semian_state

# Cleanup
Semian.destroy(:my_service)
