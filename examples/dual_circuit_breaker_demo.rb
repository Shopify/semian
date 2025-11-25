#!/usr/bin/env ruby
# frozen_string_literal: true

require "bundler/setup"
require "semian"

# Example: Dual Circuit Breaker Demo
# This demonstrates how to use both legacy and adaptive circuit breakers
# simultaneously, switching between them at runtime based on a callable.

# Simulate a feature flag that can be toggled
class FeatureFlags
  @flags = {}

  def self.enable(flag)
    @flags[flag] = true
  end

  def self.disable(flag)
    @flags[flag] = false
  end

  def self.enabled?(flag)
    @flags[flag] || false
  end
end

# Register a resource with dual circuit breaker mode
resource = Semian.register(
  :my_service,
  # Enable dual circuit breaker mode
  dual_circuit_breaker: true,

  # Provide a callable that determines which circuit breaker to use
  # Returns true = use adaptive, false = use legacy
  use_adaptive: -> { FeatureFlags.enabled?(:use_adaptive_circuit_breaker) },

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
puts "-" * 50

FeatureFlags.disable(:use_adaptive_circuit_breaker)

5.times do |i|
  result = Semian[:my_service].acquire do
    simulate_call(success: i < 3) # First 3 succeed, rest fail
  end
  puts "  Request #{i + 1}: #{result}"
rescue => e
  puts "  Request #{i + 1}: Failed - #{e.class.name}: #{e.message}"
end

# Get metrics
metrics = resource.circuit_breaker.metrics
puts "\nMetrics after Phase 1:"
puts "  Active breaker: #{metrics[:active]}"
puts "  Legacy state: #{metrics[:legacy][:state]}"
puts "  Adaptive rejection rate: #{metrics[:adaptive][:rejection_rate]}"

# Reset both circuit breakers
puts "\n" + "=" * 50
puts "Resetting circuit breakers..."
resource.circuit_breaker.reset

# Test with adaptive circuit breaker (use_adaptive returns true)
puts "\nPhase 2: Using ADAPTIVE circuit breaker (use_adaptive=true)"
puts "-" * 50

FeatureFlags.enable(:use_adaptive_circuit_breaker)

5.times do |i|
  begin
    result = Semian[:my_service].acquire do
      simulate_call(success: i < 3) # First 3 succeed, rest fail
    end
    puts "  Request #{i + 1}: #{result}"
  rescue => e
    puts "  Request #{i + 1}: Failed - #{e.class.name}: #{e.message}"
  end
  sleep 0.1 # Small delay to see adaptive behavior
end

# Get metrics
metrics = resource.circuit_breaker.metrics
puts "\nMetrics after Phase 2:"
puts "  Active breaker: #{metrics[:active]}"
puts "  Legacy state: #{metrics[:legacy][:state]}"
puts "  Adaptive rejection rate: #{metrics[:adaptive][:rejection_rate]}"

# Demonstrate dynamic switching
puts "\n" + "=" * 50
puts "Phase 3: Dynamic switching between circuit breakers"
puts "-" * 50

5.times do |i|
  # Toggle every 2 requests
  if i.even?
    FeatureFlags.disable(:use_adaptive_circuit_breaker)
    puts "  Switched to LEGACY"
  else
    FeatureFlags.enable(:use_adaptive_circuit_breaker)
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
puts "was used for decision-making based on the use_adaptive callable."

# Final metrics
metrics = resource.circuit_breaker.metrics
puts "\nFinal Metrics:"
puts "  Active breaker: #{metrics[:active]}"
puts "  Legacy: #{metrics[:legacy].inspect}"
puts "  Adaptive: #{metrics[:adaptive].inspect}"

# Cleanup
Semian.destroy(:my_service)
