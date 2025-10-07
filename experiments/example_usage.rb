#!/usr/bin/env ruby
# frozen_string_literal: true

# Add lib to load path for local development
$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "semian"
require_relative "experimental_resource"

# Example usage of the ExperimentalResource with random endpoint selection

# Create an experimental resource with 500 endpoints
resource = Semian::Experiments::ExperimentalResource.new(
  name: "experiment_service",
  endpoints_count: 500,
  min_latency: 0.01, # 10ms minimum
  max_latency: 10.0, # 10s maximum
  distribution: {
    type: :log_normal,
    mean: 0.1, # 100ms average
    std_dev: 1, # 1s standard deviation
  },
)

puts "Starting experiment with #{resource.endpoints_count} endpoints"
puts "Latency range: #{resource.min_latency}s - #{resource.max_latency}s"
puts "Distribution: #{resource.distribution}"
puts

# Make 1000 random requests and collect latencies
num_requests = 1000
latencies = []
endpoint_hits = Hash.new(0)

puts "Making #{num_requests} random requests..."
num_requests.times do |i|
  # Select random endpoint
  endpoint_idx = rand(resource.endpoints_count)
  endpoint_hits[endpoint_idx] += 1

  result = resource.request(endpoint_idx)
  latencies << result[:latency]

  # Show progress every 100 requests
  if (i + 1) % 100 == 0
    print "\rProgress: #{i + 1}/#{num_requests}"
  end
end
puts "\n"

# Calculate statistics
sorted_latencies = latencies.sort
mean = latencies.sum / latencies.size
median = sorted_latencies[sorted_latencies.size / 2]
p95 = sorted_latencies[(sorted_latencies.size * 0.95).to_i]
p99 = sorted_latencies[(sorted_latencies.size * 0.99).to_i]
min_latency = sorted_latencies.first
max_latency = sorted_latencies.last

puts "=== Latency Statistics (in ms) ==="
puts "Min:    #{(min_latency * 1000).round(2)}ms"
puts "Mean:   #{(mean * 1000).round(2)}ms"
puts "Median: #{(median * 1000).round(2)}ms"
puts "P95:    #{(p95 * 1000).round(2)}ms"
puts "P99:    #{(p99 * 1000).round(2)}ms"
puts "Max:    #{(max_latency * 1000).round(2)}ms"
puts

# Create histogram buckets
def create_histogram(latencies, num_buckets = 30)
  min = latencies.min
  max = latencies.max
  bucket_size = (max - min) / num_buckets.to_f

  buckets = Array.new(num_buckets) { 0 }
  bucket_labels = []

  latencies.each do |latency|
    bucket_idx = ((latency - min) / bucket_size).to_i
    bucket_idx = num_buckets - 1 if bucket_idx >= num_buckets
    buckets[bucket_idx] += 1
  end

  # Generate labels for buckets
  num_buckets.times do |i|
    start_val = min + (i * bucket_size)
    end_val = min + ((i + 1) * bucket_size)
    bucket_labels << [(start_val * 1000).round(0), (end_val * 1000).round(0)]
  end

  [buckets, bucket_labels]
end

# Generate ASCII histogram
puts "=== Latency Distribution Histogram ==="
buckets, labels = create_histogram(latencies)
max_count = buckets.max
scale = 50.0 / max_count # Scale to 50 character width

labels.each_with_index do |label, i|
  count = buckets[i]
  bar_length = (count * scale).to_i
  bar = "#" * bar_length
  percentage = (count * 100.0 / latencies.size).round(1)

  # Format label to be consistent width
  label_str = format("%4d-%4dms", label[0], label[1])
  count_str = format("(%3d, %4.1f%%)", count, percentage)

  puts "#{label_str} #{count_str} | #{bar}"
end

puts
puts "=== Endpoint Hit Distribution ==="
hit_counts = endpoint_hits.values.sort.reverse
puts "Most hit endpoint: #{endpoint_hits.max_by { |_, v| v }[1]} times"
puts "Least hit endpoint: #{hit_counts.last} times"
puts "Average hits per endpoint: #{(num_requests.to_f / resource.endpoints_count).round(2)}"

# Show top 5 most accessed endpoints
puts "\nTop 5 most accessed endpoints:"
endpoint_hits.sort_by { |_, v| -v }.first(5).each do |endpoint, hits|
  latency_ms = (resource.base_latency(endpoint) * 1000).round(2)
  puts "  Endpoint #{endpoint}: #{hits} hits (base latency: #{latency_ms}ms)"
end
