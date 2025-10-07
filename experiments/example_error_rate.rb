#!/usr/bin/env ruby
# frozen_string_literal: true

# Add lib to load path for local development
$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "semian"
require_relative "experimental_resource"

# Example demonstrating error rate functionality

# Create a resource with baseline error rate
resource = Semian::Experiments::ExperimentalResource.new(
  name: "error_test_service",
  endpoints_count: 10,
  min_latency: 0.01,  # 10ms minimum
  max_latency: 0.5,   # 500ms maximum
  distribution: {
    type: :log_normal,
    mean: 0.05,        # 50ms average
    std_dev: 0.03,     # 30ms standard deviation
  },
  error_rate: 0.1,     # 10% baseline error rate
)

puts "=== Error Rate Configuration ==="
puts "Baseline error rate: #{(resource.error_rate * 100).round(1)}%"
puts "Total endpoints: #{resource.endpoints_count}"
puts

# Test requests to show error behavior
puts "=== Testing Individual Requests ==="
puts "Making 20 requests to endpoint 0:"
puts

successes = 0
errors = 0

20.times do |i|
  result = resource.request(0)
  successes += 1
  puts "  #{i + 1}. ✓ Success (latency: #{(result[:latency] * 1000).round(2)}ms)"
rescue Semian::Experiments::ExperimentalResource::RequestError => e
  errors += 1
  puts "  #{i + 1}. ✗ Error: #{e.message}"
end

puts
puts "Results for endpoint 0:"
puts "  Successes: #{successes}/20 (#{(successes * 100.0 / 20).round(1)}%)"
puts "  Errors: #{errors}/20 (#{(errors * 100.0 / 20).round(1)}%)"
puts

# Test degraded endpoint with higher error rate
puts "=== Testing Degraded Endpoint ==="
puts "Degrading endpoint 1 (error rate doubles when degraded)..."
resource.degrade_endpoint(1)

normal_error_rate = resource.error_rate
degraded_error_rate = [resource.error_rate * 2, 1.0].min
puts "  Normal error rate: #{(normal_error_rate * 100).round(1)}%"
puts "  Degraded error rate: #{(degraded_error_rate * 100).round(1)}%"
puts

puts "Making 20 requests to degraded endpoint 1:"
degraded_successes = 0
degraded_errors = 0

20.times do |i|
  result = resource.request(1)
  degraded_successes += 1
  puts "  #{i + 1}. ✓ Success (latency: #{(result[:latency] * 1000).round(2)}ms, degraded: #{result[:degraded]})"
rescue Semian::Experiments::ExperimentalResource::RequestError => e
  degraded_errors += 1
  puts "  #{i + 1}. ✗ Error: #{e.message}"
end

puts
puts "Results for degraded endpoint 1:"
puts "  Successes: #{degraded_successes}/20 (#{(degraded_successes * 100.0 / 20).round(1)}%)"
puts "  Errors: #{degraded_errors}/20 (#{(degraded_errors * 100.0 / 20).round(1)}%)"
puts

# Restore endpoint
resource.restore_endpoint(1)

# Large scale testing across all endpoints
puts "=== Large Scale Testing ==="
puts "Making 1000 random requests across all endpoints..."

total_requests = 1000
endpoint_stats = Hash.new { |h, k| h[k] = { successes: 0, errors: 0, timeouts: 0 } }
overall_successes = 0
overall_errors = 0
overall_latencies = []

total_requests.times do |i|
  endpoint_idx = rand(resource.endpoints_count)

  begin
    result = resource.request(endpoint_idx)
    endpoint_stats[endpoint_idx][:successes] += 1
    overall_successes += 1
    overall_latencies << result[:latency]
  rescue Semian::Experiments::ExperimentalResource::RequestError => e
    endpoint_stats[endpoint_idx][:errors] += 1
    overall_errors += 1
  rescue Semian::Experiments::ExperimentalResource::TimeoutError => e
    endpoint_stats[endpoint_idx][:timeouts] += 1
  end

  # Show progress
  if (i + 1) % 100 == 0
    print "\rProgress: #{i + 1}/#{total_requests}"
  end
end
puts

puts
puts "=== Overall Statistics ==="
puts "Total requests: #{total_requests}"
puts "Successful: #{overall_successes} (#{(overall_successes * 100.0 / total_requests).round(1)}%)"
puts "Failed: #{overall_errors} (#{(overall_errors * 100.0 / total_requests).round(1)}%)"

if overall_latencies.any?
  avg_latency = overall_latencies.sum / overall_latencies.size
  puts "Average latency for successful requests: #{(avg_latency * 1000).round(2)}ms"
end
puts

puts "=== Per-Endpoint Error Statistics ==="
resource.endpoints_count.times do |idx|
  stats = endpoint_stats[idx]
  total = stats[:successes] + stats[:errors] + stats[:timeouts]

  next unless total > 0

  error_rate = (stats[:errors] * 100.0 / total).round(1)
  base_latency = resource.base_latency(idx)
  puts "Endpoint #{idx}: #{total.to_s.rjust(3)} requests, " \
    "#{stats[:errors].to_s.rjust(2)} errors (#{error_rate.to_s.rjust(5)}%), " \
    "base latency: #{(base_latency * 1000).round(2).to_s.rjust(7)}ms"
end

# Test different error rates
puts
puts "=== Impact of Different Error Rates ==="

error_rates = [0.0, 0.05, 0.1, 0.2, 0.5]
test_requests = 200

error_rates.each do |error_rate|
  test_resource = Semian::Experiments::ExperimentalResource.new(
    name: "test_#{error_rate}",
    endpoints_count: 5,
    min_latency: 0.01,
    max_latency: 0.1,
    distribution: { type: :log_normal, mean: 0.02, std_dev: 0.01 },
    error_rate: error_rate,
  )

  errors = 0
  test_requests.times do
    test_resource.request(rand(test_resource.endpoints_count))
  rescue Semian::Experiments::ExperimentalResource::RequestError
    errors += 1
  end

  actual_error_rate = (errors * 100.0 / test_requests).round(1)
  expected_error_rate = (error_rate * 100).round(1)

  puts "Error rate #{expected_error_rate.to_s.rjust(5)}%: " \
    "#{errors.to_s.rjust(3)}/#{test_requests} failed " \
    "(actual: #{actual_error_rate.to_s.rjust(5)}%)"
end

# Test combined effects: error rate + degradation
puts
puts "=== Combined Effects: Error Rate + Degradation ==="

combined_resource = Semian::Experiments::ExperimentalResource.new(
  name: "combined_test",
  endpoints_count: 3,
  min_latency: 0.01,
  max_latency: 0.2,
  distribution: { type: :log_normal, mean: 0.03, std_dev: 0.02 },
  error_rate: 0.15, # 15% baseline error rate
)

puts "Baseline error rate: #{(combined_resource.error_rate * 100).round(1)}%"
puts

# Test each endpoint
3.times do |endpoint_idx|
  # Test normal
  normal_errors = 0
  50.times do
    combined_resource.request(endpoint_idx)
  rescue Semian::Experiments::ExperimentalResource::RequestError
    normal_errors += 1
  end

  # Test degraded
  combined_resource.degrade_endpoint(endpoint_idx)
  degraded_errors = 0
  50.times do
    combined_resource.request(endpoint_idx)
  rescue Semian::Experiments::ExperimentalResource::RequestError
    degraded_errors += 1
  end
  combined_resource.restore_endpoint(endpoint_idx)

  puts "Endpoint #{endpoint_idx}:"
  puts "  Normal: #{normal_errors}/50 errors (#{(normal_errors * 2).round(0)}%)"
  puts "  Degraded: #{degraded_errors}/50 errors (#{(degraded_errors * 2).round(0)}%)"
end
