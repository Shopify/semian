#!/usr/bin/env ruby
# frozen_string_literal: true

require "bundler/setup"
require "semian"

# Example of configuring Semian with the adaptive circuit breaker

puts "=" * 60
puts "Adaptive Circuit Breaker Configuration Examples"
puts "=" * 60

# 1. Basic adaptive circuit breaker configuration
puts "\n1. Basic Adaptive Configuration:"
puts "-" * 40

resource1 = Semian.register(
  :mysql_shard1,
  adaptive_circuit_breaker: true,  # Enable adaptive circuit breaker
  bulkhead: false,                 # Disable bulkhead for this example
)

puts "Created resource: #{resource1.name}"
puts "Circuit breaker type: #{resource1.circuit_breaker.class}"
puts "Initial metrics: #{resource1.circuit_breaker.metrics}"

# 2. Combined with bulkhead
puts "\n2. Adaptive Circuit Breaker + Bulkhead:"
puts "-" * 40

resource2 = Semian.register(
  :api_service,
  # Adaptive circuit breaker
  adaptive_circuit_breaker: true,

  # Bulkhead config
  bulkhead: true,
  tickets: 10,
  timeout: 0.5,
)

puts "Created resource: #{resource2.name}"
puts "Has circuit breaker: #{!resource2.circuit_breaker.nil?}"
puts "Has bulkhead: #{!resource2.bulkhead.nil?}"
puts "Bulkhead tickets: #{resource2.tickets}"

# 3. Traditional circuit breaker (for comparison)
puts "\n3. Traditional Circuit Breaker (for comparison):"
puts "-" * 40

resource3 = Semian.register(
  :traditional_service,
  circuit_breaker: true,
  success_threshold: 2,
  error_threshold: 3,
  error_timeout: 10,
  bulkhead: false,
)

puts "Created resource: #{resource3.name}"
puts "Circuit breaker type: #{resource3.circuit_breaker.class}"

# 4. Disable adaptive via environment variable
puts "\n4. Disabling via Environment Variable:"
puts "-" * 40

ENV["SEMIAN_ADAPTIVE_CIRCUIT_BREAKER_DISABLED"] = "1"

resource4 = Semian.register(
  :should_be_disabled,
  adaptive_circuit_breaker: true, # Will be ignored due to ENV var
  bulkhead: true,
  tickets: 1,
)

puts "Created resource: #{resource4.name}"
puts "Circuit breaker: #{resource4.circuit_breaker.nil? ? "disabled" : "enabled"}"
puts "Bulkhead: #{resource4.bulkhead.nil? ? "disabled" : "enabled"}"

ENV.delete("SEMIAN_ADAPTIVE_CIRCUIT_BREAKER_DISABLED")

# 5. Using the resource with adaptive circuit breaker
puts "\n5. Using Adaptive Circuit Breaker:"
puts "-" * 40

# Mock resource that can be pinged
class MockResource
  def ping
    rand > 0.2 ? "pong" : raise("ping failed")
  end
end

mock_resource = MockResource.new

# Simulate some requests
5.times do |i|
  resource1.acquire(resource: mock_resource) do
    if rand > 0.7
      raise "Simulated error"
    end

    puts "Request #{i + 1}: Success"
  end
rescue Semian::OpenCircuitError => e
  puts "Request #{i + 1}: Circuit open - #{e.message}"
rescue => e
  puts "Request #{i + 1}: Error - #{e.message}"
end

# Check final metrics
puts "\nFinal metrics for adaptive circuit breaker:"
puts resource1.circuit_breaker.metrics

# Clean up
puts "\n6. Cleanup:"
puts "-" * 40
Semian.destroy_all_resources
puts "All resources destroyed"

puts "\n" + "=" * 60
puts "Configuration examples complete!"
puts "=" * 60

puts "\nKey Takeaways:"
puts "- Use 'adaptive_circuit_breaker: true' to enable"
puts "- Traditional params (error_threshold, etc.) are ignored when adaptive is enabled"
puts "- Can be combined with bulkhead"
puts "- Can be disabled via SEMIAN_ADAPTIVE_CIRCUIT_BREAKER_DISABLED env var"
puts "- The adaptive circuit breaker automatically adjusts based on service health"
puts "- No manual tuning required - uses optimized internal parameters"
