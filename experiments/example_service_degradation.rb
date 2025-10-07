#!/usr/bin/env ruby
# frozen_string_literal: true

# Add lib to load path for local development
$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "semian"
require_relative "experimental_resource"

# Example demonstrating service-wide degradation with ramp-up

# Create a resource
resource = Semian::Experiments::ExperimentalResource.new(
  name: "degradation_test",
  endpoints_count: 5,
  min_latency: 0.01,  # 10ms minimum
  max_latency: 0.5,   # 500ms maximum
  distribution: {
    type: :log_normal,
    mean: 0.05,        # 50ms average
    std_dev: 0.02,     # 20ms standard deviation
  },
  error_rate: 0.05, # 5% baseline error rate
)

puts "=== Resource Configuration ==="
puts "Endpoints: #{resource.endpoints_count}"
puts "Baseline error rate: #{(resource.base_error_rate * 100).round(1)}%"
puts "Endpoint base latencies:"
resource.endpoints_count.times do |i|
  puts "  Endpoint #{i}: #{(resource.base_latency(i) * 1000).round(2)}ms"
end
puts

# Helper method to make test requests
def make_test_requests(resource, count: 10, label: "Test")
  successes = 0
  errors = 0
  latencies = []

  count.times do
    endpoint = rand(resource.endpoints_count)
    begin
      result = resource.request(endpoint)
      successes += 1
      latencies << result[:latency]
    rescue Semian::Experiments::ExperimentalResource::RequestError
      errors += 1
    rescue Semian::Experiments::ExperimentalResource::TimeoutError
      errors += 1
    end
  end

  avg_latency = latencies.empty? ? 0 : latencies.sum / latencies.size

  puts "#{label}: #{successes}/#{count} successful, " \
    "avg latency: #{(avg_latency * 1000).round(2)}ms, " \
    "error rate: #{(errors * 100.0 / count).round(1)}%"
end

# Test baseline performance
puts "=== Baseline Performance ==="
make_test_requests(resource, count: 20, label: "Baseline")
puts

# Test immediate latency degradation
puts "=== Immediate Latency Degradation ==="
puts "Adding 200ms to all requests (immediate)"
resource.add_latency(0.2) # Add 200ms

puts "Current latency degradation: #{(resource.current_latency_degradation * 1000).round(2)}ms"
make_test_requests(resource, count: 20, label: "With +200ms")
puts

# Reset and test gradual latency degradation
puts "=== Gradual Latency Degradation ==="
resource.reset_degradation
puts "Service reset to baseline"

puts "Adding 300ms over 3 seconds..."
resource.add_latency(0.3, ramp_time: 3)

# Sample during ramp-up
3.times do |i|
  sleep(1)
  puts "After #{i + 1}s - Current degradation: #{(resource.current_latency_degradation * 1000).round(2)}ms"
  make_test_requests(resource, count: 10, label: "  Ramp #{i + 1}s")
end

sleep(0.5) # Ensure ramp is complete
puts "After ramp complete - Current degradation: #{(resource.current_latency_degradation * 1000).round(2)}ms"
make_test_requests(resource, count: 20, label: "Full degradation")
puts

# Test immediate error rate change
puts "=== Immediate Error Rate Change ==="
resource.reset_degradation
puts "Service reset to baseline"

puts "Setting error rate to 30% (immediate)"
resource.set_error_rate(0.3)

puts "Current error rate: #{(resource.current_error_rate * 100).round(1)}%"
make_test_requests(resource, count: 30, label: "With 30% errors")
puts

# Test gradual error rate increase
puts "=== Gradual Error Rate Increase ==="
resource.reset_degradation
puts "Service reset to baseline (5% error rate)"

puts "Ramping error rate to 50% over 5 seconds..."
resource.set_error_rate(0.5, ramp_time: 5)

# Sample during ramp-up
5.times do |i|
  sleep(1)
  current_rate = resource.current_error_rate
  puts "After #{i + 1}s - Current error rate: #{(current_rate * 100).round(1)}%"
  make_test_requests(resource, count: 20, label: "  Ramp #{i + 1}s")
end

sleep(0.5) # Ensure ramp is complete
puts "After ramp complete - Current error rate: #{(resource.current_error_rate * 100).round(1)}%"
make_test_requests(resource, count: 30, label: "Full error rate")
puts

# Test combined degradation
puts "=== Combined Degradation ==="
resource.reset_degradation
puts "Service reset to baseline"

puts "Applying both latency and error rate degradation with ramp-up:"
puts "  - Adding 150ms latency over 2 seconds"
puts "  - Increasing error rate to 25% over 3 seconds"

resource.add_latency(0.15, ramp_time: 2)
resource.set_error_rate(0.25, ramp_time: 3)

# Monitor the combined ramp-up
4.times do |i|
  sleep(1)
  lat_deg = resource.current_latency_degradation
  err_rate = resource.current_error_rate

  puts "\nAfter #{i + 1}s:"
  puts "  Latency degradation: #{(lat_deg * 1000).round(2)}ms"
  puts "  Error rate: #{(err_rate * 100).round(1)}%"
  make_test_requests(resource, count: 20, label: "  Combined #{i + 1}s")
end
puts

# Test reset
puts "=== Reset to Baseline ==="
resource.reset_degradation
puts "Service reset to baseline"
puts "Current latency degradation: #{(resource.current_latency_degradation * 1000).round(2)}ms"
puts "Current error rate: #{(resource.current_error_rate * 100).round(1)}%"
make_test_requests(resource, count: 20, label: "After reset")
puts

# Demonstrate realistic failure scenario
puts "=== Realistic Failure Scenario ==="
puts "Simulating a gradual service degradation:"
puts "  Phase 1: Small latency increase"
puts "  Phase 2: Error rate starts climbing"
puts "  Phase 3: Both get worse"
puts "  Phase 4: Recovery"
puts

# Phase 1: Small latency increase
puts "Phase 1: Latency starts increasing (0-2s)"
resource.add_latency(0.1, ramp_time: 2)
sleep(2)
make_test_requests(resource, count: 20, label: "Phase 1")

# Phase 2: Error rate climbs
puts "\nPhase 2: Errors start appearing (2-4s)"
resource.set_error_rate(0.15, ramp_time: 2)
sleep(2)
make_test_requests(resource, count: 20, label: "Phase 2")

# Phase 3: Both get worse
puts "\nPhase 3: Service severely degraded (4-6s)"
resource.add_latency(0.3, ramp_time: 2)
resource.set_error_rate(0.4, ramp_time: 2)
sleep(2)
make_test_requests(resource, count: 20, label: "Phase 3")

# Phase 4: Recovery
puts "\nPhase 4: Service recovery (6-10s)"
resource.add_latency(0, ramp_time: 4)
resource.set_error_rate(0.05, ramp_time: 4)

2.times do |i|
  sleep(2)
  make_test_requests(resource, count: 20, label: "Recovery #{(i + 1) * 2}s")
end

puts "\nFinal state:"
puts "  Latency degradation: #{(resource.current_latency_degradation * 1000).round(2)}ms"
puts "  Error rate: #{(resource.current_error_rate * 100).round(1)}%"
