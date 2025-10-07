#!/usr/bin/env ruby
# frozen_string_literal: true

# Add lib to load path for local development
$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "semian"
require_relative "experimental_resource"

# Example showing Semian circuit breaker with config in 'semian' key

puts "=== Semian Circuit Breaker Integration Example ==="
puts

# Create resource with Semian config in a clean 'semian' key
resource = Semian::Experiments::ExperimentalResource.new(
  name: "protected_service",
  endpoints_count: 3,
  min_latency: 0.01,
  max_latency: 0.1,
  distribution: {
    type: :log_normal,
    mean: 0.03,
    std_dev: 0.01,
  },
  error_rate: 0.1, # 10% baseline error rate
  timeout: 0.5, # 500ms timeout
  # Semian configuration in its own key - clean separation!
  semian: {
    success_threshold: 2,
    error_threshold: 3,
    error_timeout: 3,
    bulkhead: false,
  },
)

puts "Resource created with:"
puts "  Name: #{resource.semian_identifier}"
puts "  Endpoints: #{resource.endpoints_count}"
puts "  Error rate: #{(resource.base_error_rate * 100).round(1)}%"
puts "  Timeout: #{resource.timeout}s"
puts "  Semian circuit breaker: configured"
puts

# Test 1: Normal operation
puts "=== Test 1: Normal Operation ==="
puts "Making requests with 10% error rate:"
5.times do |i|
  result = resource.request(i % resource.endpoints_count)
  puts "  Request #{i + 1}: ✓ Success (#{(result[:latency] * 1000).round(2)}ms)"
rescue Semian::Experiments::ExperimentalResource::CircuitOpenError => e
  puts "  Request #{i + 1}: ⚡ Circuit Open - #{e.message}"
rescue Semian::Experiments::ExperimentalResource::RequestError => e
  puts "  Request #{i + 1}: ✗ Error"
end
puts

# Test 2: Trigger circuit breaker
puts "=== Test 2: Triggering Circuit Breaker ==="
puts "Increasing error rate to 100% to trigger circuit..."
resource.set_error_rate(1.0)
puts

10.times do |i|
  result = resource.request(0)
  puts "  Request #{i + 1}: Success"
rescue Semian::Experiments::ExperimentalResource::CircuitOpenError => e
  puts "  Request #{i + 1}: ⚡ CIRCUIT OPENED!"
  puts "  Circuit breaker is protecting the service"
  break
rescue Semian::Experiments::ExperimentalResource::RequestError => e
  puts "  Request #{i + 1}: Error"
end
puts

# Test 3: Circuit remains open
puts "=== Test 3: Circuit Open Behavior ==="
puts "Attempting more requests while circuit is open:"
3.times do |i|
  resource.request(0)
  puts "  Request #{i + 1}: Success (unexpected)"
rescue Semian::Experiments::ExperimentalResource::CircuitOpenError => e
  puts "  Request #{i + 1}: Blocked by circuit (fail-fast)"
rescue Semian::Experiments::ExperimentalResource::RequestError => e
  puts "  Request #{i + 1}: Error (unexpected)"
end
puts

# Test 4: Circuit recovery
puts "=== Test 4: Circuit Recovery ==="
puts "Reducing error rate to 0% for recovery..."
resource.set_error_rate(0)
puts "Waiting 3 seconds for circuit timeout..."
sleep(3)
puts

puts "Making recovery requests:"
5.times do |i|
  result = resource.request(0)
  puts "  Request #{i + 1}: ✓ Success - Circuit recovered!"
rescue Semian::Experiments::ExperimentalResource::CircuitOpenError => e
  puts "  Request #{i + 1}: Still blocked (may need more successes)"
rescue Semian::Experiments::ExperimentalResource::RequestError => e
  puts "  Request #{i + 1}: Error"
end
puts
