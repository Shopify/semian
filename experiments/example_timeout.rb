#!/usr/bin/env ruby
# frozen_string_literal: true

# Add lib to load path for local development
$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "semian"
require_relative "experimental_resource"

# Example demonstrating timeout functionality

# Create a resource with timeout enabled
resource = Semian::Experiments::ExperimentalResource.new(
  name: "timeout_test_service",
  endpoints_count: 10,
  min_latency: 0.01,  # 10ms minimum
  max_latency: 5.0,   # 5s maximum
  distribution: {
    type: :log_normal,
    mean: 0.5,        # 500ms average
    std_dev: 1.5,      # High variance to create some slow endpoints
  },
  timeout: 1.0,        # 1 second timeout
)

puts "=== Timeout Configuration ==="
puts "Timeout threshold: #{resource.timeout}s (#{(resource.timeout * 1000).round}ms)"
puts "Total endpoints: #{resource.endpoints_count}"
puts

# Display endpoint latencies and identify which would timeout
puts "=== Endpoint Analysis ==="
resource.endpoints_count.times do |i|
  base_latency = resource.base_latency(i)
  would_timeout = resource.would_timeout?(i)
  status = would_timeout ? "⚠️  TIMEOUT" : "✓  OK"

  puts "Endpoint #{i}: #{(base_latency * 1000).round(2).to_s.rjust(8)}ms #{status}"
end

timeout_endpoints = resource.timeout_endpoints
puts
puts "Summary: #{timeout_endpoints.size} out of #{resource.endpoints_count} endpoints would timeout"
puts "Timeout endpoints: #{timeout_endpoints.inspect}" if timeout_endpoints.any?
puts

# Make requests to demonstrate timeout behavior
puts "=== Testing Requests ==="
puts

# Test a fast endpoint
fast_endpoint = (0...resource.endpoints_count).find { |i| !resource.would_timeout?(i) }
if fast_endpoint
  puts "Testing fast endpoint #{fast_endpoint}:"
  start_time = Time.now
  result = resource.request(fast_endpoint)
  elapsed = Time.now - start_time
  puts "  ✓ Success: Completed in #{(elapsed * 1000).round(2)}ms"
  puts "  Response: #{result}"
  puts
end

# Test a slow endpoint that would timeout
slow_endpoint = timeout_endpoints.first
if slow_endpoint
  puts "Testing slow endpoint #{slow_endpoint} (expected to timeout):"
  start_time = Time.now
  begin
    resource.request(slow_endpoint)
    puts "  ✗ Unexpected: Request succeeded"
  rescue Semian::Experiments::ExperimentalResource::TimeoutError => e
    elapsed = Time.now - start_time
    puts "  ✓ Expected timeout after #{(elapsed * 1000).round(2)}ms"
    puts "  Error: #{e.message}"
  end
  puts
end

# Test degraded endpoint behavior with timeout
if fast_endpoint
  puts "=== Testing Degradation with Timeout ==="
  puts "Degrading endpoint #{fast_endpoint}..."
  resource.degrade_endpoint(fast_endpoint)

  base_latency = resource.base_latency(fast_endpoint)
  degraded_latency = base_latency * 2

  puts "Base latency: #{(base_latency * 1000).round(2)}ms"
  puts "Degraded latency: #{(degraded_latency * 1000).round(2)}ms"
  puts "Will timeout? #{degraded_latency > resource.timeout}"
  puts

  puts "Making request to degraded endpoint #{fast_endpoint}:"
  start_time = Time.now
  begin
    result = resource.request(fast_endpoint)
    elapsed = Time.now - start_time
    puts "  ✓ Completed in #{(elapsed * 1000).round(2)}ms (within timeout)"
    puts "  Response: #{result}"
  rescue Semian::Experiments::ExperimentalResource::TimeoutError => e
    elapsed = Time.now - start_time
    puts "  ⚠️  Timed out after #{(elapsed * 1000).round(2)}ms"
    puts "  Error: #{e.message}"
  end

  # Restore the endpoint
  resource.restore_endpoint(fast_endpoint)
  puts
end

# Batch testing with statistics
puts "=== Batch Request Statistics ==="
puts "Making 100 requests to random endpoints..."

successes = 0
timeouts = 0
total_latency = 0
timeout_details = []

100.times do |i|
  endpoint_idx = rand(resource.endpoints_count)

  begin
    start_time = Time.now
    resource.request(endpoint_idx)
    elapsed = Time.now - start_time
    successes += 1
    total_latency += elapsed
  rescue Semian::Experiments::ExperimentalResource::TimeoutError => e
    timeouts += 1
    timeout_details << { endpoint: endpoint_idx, message: e.message }
  end

  # Show progress
  print "\rProgress: #{i + 1}/100 (Successes: #{successes}, Timeouts: #{timeouts})"
end
puts

puts
puts "Results:"
puts "  Successful requests: #{successes}/100 (#{(successes * 100.0 / 100).round(1)}%)"
puts "  Timed out requests:  #{timeouts}/100 (#{(timeouts * 100.0 / 100).round(1)}%)"
if successes > 0
  avg_latency = total_latency / successes
  puts "  Average latency for successful requests: #{(avg_latency * 1000).round(2)}ms"
end

# Test with different timeout values
puts
puts "=== Impact of Different Timeout Values ==="

timeout_values = [0.1, 0.5, 1.0, 2.0, 5.0]
original_timeout = resource.timeout

timeout_values.each do |timeout_val|
  # Create a new resource with the same distribution but different timeout
  test_resource = Semian::Experiments::ExperimentalResource.new(
    name: "timeout_test_#{timeout_val}",
    endpoints_count: resource.endpoints_count,
    min_latency: resource.min_latency,
    max_latency: resource.max_latency,
    distribution: resource.distribution,
    timeout: timeout_val,
  )

  timeout_count = test_resource.timeout_endpoints.size
  percentage = (timeout_count * 100.0 / test_resource.endpoints_count).round(1)

  puts "Timeout #{(timeout_val * 1000).round.to_s.rjust(4)}ms: " \
    "#{timeout_count.to_s.rjust(2)}/#{test_resource.endpoints_count} endpoints would timeout " \
    "(#{percentage.to_s.rjust(5)}%)"
end
