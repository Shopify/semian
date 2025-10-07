#!/usr/bin/env ruby
# frozen_string_literal: true

# Add lib to load path for local development
$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "semian"
require_relative "experimental_resource"

# Check if gruff is installed, if not provide instructions
begin
  require "gruff"
rescue LoadError
  puts "The 'gruff' gem is required for graphing. Please install it with:"
  puts "  gem install gruff"
  puts ""
  puts "Note: gruff requires ImageMagick or GraphicsMagick to be installed."
  puts "On macOS: brew install imagemagick"
  puts "On Ubuntu: apt-get install imagemagick"
  exit(1)
end

# Example usage of the ExperimentalResource with graphical output

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
  latencies << result[:latency] * 1000 # Convert to ms

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
puts "Min:    #{min_latency.round(2)}ms"
puts "Mean:   #{mean.round(2)}ms"
puts "Median: #{median.round(2)}ms"
puts "P95:    #{p95.round(2)}ms"
puts "P99:    #{p99.round(2)}ms"
puts "Max:    #{max_latency.round(2)}ms"
puts

# Create histogram buckets for graphing
def create_histogram_data(latencies, num_buckets = 20)
  min = latencies.min
  max = latencies.max
  bucket_size = (max - min) / num_buckets.to_f

  buckets = Array.new(num_buckets) { 0 }
  bucket_labels = []
  bucket_centers = []

  latencies.each do |latency|
    bucket_idx = ((latency - min) / bucket_size).to_i
    bucket_idx = num_buckets - 1 if bucket_idx >= num_buckets
    buckets[bucket_idx] += 1
  end

  # Generate labels and center points for buckets
  num_buckets.times do |i|
    start_val = min + (i * bucket_size)
    end_val = min + ((i + 1) * bucket_size)
    center_val = (start_val + end_val) / 2

    # Create shorter labels for readability
    label = if end_val < 100
      "#{end_val.round(0)}"
    elsif end_val < 1000
      "#{end_val.round(0)}"
    else
      "#{(end_val / 1000).round(1)}s"
    end

    bucket_labels << label
    bucket_centers << center_val
  end

  [buckets, bucket_labels, bucket_centers]
end

# Generate histogram chart
puts "Generating histogram chart..."
buckets, labels, centers = create_histogram_data(latencies, 25)

# Create bar chart with Gruff
histogram = Gruff::Bar.new(1200, 800)
histogram.title = "Latency Distribution (#{num_requests} requests)"
histogram.x_axis_label = "Latency (ms)"
histogram.y_axis_label = "Number of Requests"
histogram.theme = {
  colors: ["#3366CC"],
  marker_color: "#666666",
  font_color: "#333333",
  background_colors: ["#FFFFFF", "#FFFFFF"],
}

# Only show every nth label to avoid overcrowding
label_interval = (labels.length / 10.0).ceil
sparse_labels = {}
labels.each_with_index do |label, i|
  sparse_labels[i] = label if i % label_interval == 0 || i == labels.length - 1
end
histogram.labels = sparse_labels

histogram.data("Latency", buckets)
histogram.minimum_value = 0
histogram.maximum_value = buckets.max + (buckets.max * 0.1) # Add 10% padding

output_file = "experiments/latency_histogram.png"
histogram.write(output_file)
puts "Histogram saved to: #{output_file}"

# Create a line chart showing cumulative distribution
puts "Generating cumulative distribution chart..."
cumulative = Gruff::Line.new(1200, 800)
cumulative.title = "Cumulative Latency Distribution"
cumulative.x_axis_label = "Latency (ms)"
cumulative.y_axis_label = "Percentile"

# Calculate cumulative percentages
cumulative_data = []
total = 0
sorted_latencies.each_with_index do |latency, i|
  percentile = ((i + 1) * 100.0 / sorted_latencies.size)
  cumulative_data << [latency, percentile]
end

# Sample points for the graph (too many points make it slow)
sample_interval = [sorted_latencies.size / 100, 1].max
sampled_data = cumulative_data.select.with_index { |_, i| i % sample_interval == 0 }
sampled_data << cumulative_data.last # Ensure we include the last point

x_values = sampled_data.map(&:first)
y_values = sampled_data.map(&:last)

# Create labels for x-axis
x_labels = {}
label_count = 10
(0...label_count).each do |i|
  idx = (i * (x_values.length - 1) / (label_count - 1.0)).round
  x_labels[idx] = x_values[idx].round(0).to_s
end

cumulative.labels = x_labels
cumulative.data("Latency CDF", y_values)
cumulative.minimum_value = 0
cumulative.maximum_value = 100
cumulative.hide_dots = true
cumulative.line_width = 3

cdf_output_file = "experiments/latency_cdf.png"
cumulative.write(cdf_output_file)
puts "Cumulative distribution saved to: #{cdf_output_file}"

# Create a scatter plot showing endpoint latencies
puts "Generating endpoint latency scatter plot..."
scatter = Gruff::Scatter.new(1200, 800)
scatter.title = "Endpoint Base Latencies"
scatter.x_axis_label = "Endpoint Index"
scatter.y_axis_label = "Base Latency (ms)"

# Get base latencies for all endpoints
endpoint_indices = []
endpoint_latencies = []
(0...resource.endpoints_count).each do |i|
  endpoint_indices << i
  endpoint_latencies << resource.base_latency(i) * 1000
end

scatter.data("Endpoints", endpoint_indices, endpoint_latencies)
scatter.hide_dots = false
scatter.dot_radius = 1

scatter_output_file = "experiments/endpoint_latencies.png"
scatter.write(scatter_output_file)
puts "Endpoint scatter plot saved to: #{scatter_output_file}"

puts
puts "=== Endpoint Hit Distribution ==="
hit_counts = endpoint_hits.values.sort.reverse
puts "Most hit endpoint: #{endpoint_hits.max_by { |_, v| v }[1]} times"
puts "Least hit endpoint: #{hit_counts.min} times"
puts "Average hits per endpoint: #{(num_requests.to_f / resource.endpoints_count).round(2)}"

# Show top 5 most accessed endpoints
puts "\nTop 5 most accessed endpoints:"
endpoint_hits.sort_by { |_, v| -v }.first(5).each do |endpoint, hits|
  latency_ms = (resource.base_latency(endpoint) * 1000).round(2)
  puts "  Endpoint #{endpoint}: #{hits} hits (base latency: #{latency_ms}ms)"
end

puts "\n=== Visualization Summary ==="
puts "Generated 3 graphs:"
puts "1. #{output_file} - Histogram of latency distribution"
puts "2. #{cdf_output_file} - Cumulative distribution function"
puts "3. #{scatter_output_file} - Scatter plot of endpoint base latencies"
puts "\nYou can open these files to view the graphs."
