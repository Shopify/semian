#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "traffic_replay_experimental_resource"

# Example usage of TrafficReplayExperimentalResource with traffic replay

puts "=== Semian ExperimentalResource - Traffic Replay Example ==="
puts

# Example 1: Create a resource with traffic replay from Grafana export
puts "Example: Using traffic replay from Grafana export"
puts "-" * 60

# To use this example, you need a Grafana export JSON file
# where each line is a JSON object with:
# - "timestamp": ISO8601 timestamp
# - "attrs.db.sql.total_duration_ms": latency in milliseconds

traffic_log_path = ARGV[0] || "path/to/grafana_export.json"

unless File.exist?(traffic_log_path)
  puts "ERROR: Traffic log file not found: #{traffic_log_path}"
  puts
  puts "Usage: ruby #{__FILE__} <path_to_grafana_export.json>"
  puts
  puts "The JSON file should contain one JSON object per line, with fields:"
  puts '  - "timestamp": ISO8601 timestamp (e.g., "2025-10-02T16:19:30.814890047Z")'
  puts '  - "attrs.db.sql.total_duration_ms": latency in milliseconds'
  puts
  puts "Example JSON line:"
  puts "{"
  puts '  "timestamp": "2025-10-02T16:19:30.814890047Z",'
  puts '  "attrs.db.sql.total_duration_ms": 5.2,'
  puts "  ... other fields ..."
  puts "}"
  exit 1
end

begin
  # Create resource with traffic replay
  resource = Semian::Experiments::TrafficReplayExperimentalResource.new(
    name: "my_service",
    traffic_log_path: traffic_log_path, # Path to Grafana JSON export
    timeout: 30.0,                      # 30 second timeout
    semian: {
      circuit_breaker: true,
      success_threshold: 2,
      error_threshold: 3,
      error_threshold_timeout: 10,
    },
  )

  puts
  puts "Resource created successfully!"
  puts "Starting to process requests..."
  puts "Press Ctrl+C to stop"
  puts

  # Make requests continuously until the timeline is exhausted
  request_count = 0
  loop do
    result = resource.request do |latency|
      request_count += 1
      puts "[#{Time.now.strftime("%H:%M:%S")}] Request ##{request_count} - " \
        "Latency: #{(latency * 1000).round(2)}ms"
      { latency: latency, request_number: request_count }
    end

    # Small delay between requests to avoid overwhelming the output
    sleep(0.1)
  rescue Semian::Experiments::TrafficReplayExperimentalResource::TrafficReplayCompleteError => e
    puts
    puts "Traffic replay completed!"
    puts "Total requests processed: #{request_count}"
    break
  rescue Semian::Experiments::TrafficReplayExperimentalResource::CircuitOpenError => e
    puts "[#{Time.now.strftime("%H:%M:%S")}] Circuit breaker is OPEN - #{e.message}"
    sleep(1)
  rescue => e
    puts "[#{Time.now.strftime("%H:%M:%S")}] Error: #{e.class} - #{e.message}"
    sleep(0.5)
  end

  puts
  puts "=== Replay Complete ==="
rescue ArgumentError => e
  puts "ERROR: #{e.message}"
  exit(1)
rescue Interrupt
  puts
  puts
  puts "=== Interrupted by user ==="
  puts "Total requests processed: #{request_count}"
  exit(0)
end
