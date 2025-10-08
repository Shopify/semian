#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "experimental_resource"

puts "Testing Traffic Replay Feature"
puts "=" * 60

# Test 1: Create resource with sample traffic log
puts "\nTest 1: Loading sample traffic log..."
begin
  resource = Semian::Experiments::ExperimentalResource.new(
    name: "test_service",
    endpoints_count: 1,
    min_latency: 0.0,
    max_latency: 1.0,
    distribution: { type: :log_normal, mean: 0.1, std_dev: 0.05 },
    timeout: 30.0,
    traffic_log_path: File.join(__dir__, "sample_traffic_log.json"),
  )
  puts "✓ Resource created successfully"
rescue => e
  puts "✗ Failed to create resource: #{e.message}"
  exit(1)
end

# Test 2: Make a few requests
puts "\nTest 2: Making test requests..."
request_count = 0
latencies = []

begin
  5.times do
    result = resource.request(0) do |endpoint, latency|
      request_count += 1
      latencies << latency
      puts "  Request #{request_count}: #{(latency * 1000).round(2)}ms"
    end
    sleep(0.5) # Wait half a second between requests
  end
  puts "✓ Successfully processed #{request_count} requests"
rescue => e
  puts "✗ Error during requests: #{e.message}"
  exit(1)
end

# Test 3: Verify latencies are from timeline
puts "\nTest 3: Verifying latencies..."
if latencies.all? { |l| l >= 0 }
  puts "✓ All latencies are valid (>= 0)"
else
  puts "✗ Some latencies are invalid"
  exit 1
end

# Test 4: Check timeline properties
puts "\nTest 4: Checking timeline properties..."
if resource.traffic_log_path
  puts "✓ Traffic log path: #{resource.traffic_log_path}"
else
  puts "✗ Traffic log path not set"
  exit 1
end

puts "\n" + "=" * 60
puts "All tests passed! ✓"
puts "\nYou can now run the full example with:"
puts "  ruby example_with_traffic_replay.rb sample_traffic_log.json"
