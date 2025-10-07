#!/usr/bin/env ruby
# frozen_string_literal: true

# Add lib to load path for local development
$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "semian"
require_relative "experimental_resource"

# Generate SVG charts without external dependencies

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

# SVG Helper class
class SVGChart
  attr_reader :width, :height, :margin

  def initialize(width: 800, height: 600, margin: 60)
    @width = width
    @height = height
    @margin = margin
    @chart_width = width - 2 * margin
    @chart_height = height - 2 * margin
  end

  def create_histogram(data, labels, title: "Histogram", x_label: "X Axis", y_label: "Y Axis", filename: "histogram.svg")
    max_value = data.max
    bar_width = @chart_width / data.length

    svg = []
    svg << %{<?xml version="1.0" encoding="UTF-8"?>}
    svg << %{<svg xmlns="http://www.w3.org/2000/svg" width="#{@width}" height="#{@height}">}

    # Background
    svg << %{<rect width="#{@width}" height="#{@height}" fill="white"/>}

    # Title
    svg << %{<text x="#{@width / 2}" y="30" text-anchor="middle" font-size="20" font-weight="bold">#{title}</text>}

    # Draw axes
    svg << %{<line x1="#{@margin}" y1="#{@height - @margin}" x2="#{@width - @margin}" y2="#{@height - @margin}" stroke="black" stroke-width="2"/>}
    svg << %{<line x1="#{@margin}" y1="#{@margin}" x2="#{@margin}" y2="#{@height - @margin}" stroke="black" stroke-width="2"/>}

    # Y-axis labels and grid lines
    y_ticks = 5
    (0..y_ticks).each do |i|
      y = @height - @margin - (i * @chart_height / y_ticks)
      value = (i * max_value / y_ticks.to_f).round

      # Grid line
      svg << %{<line x1="#{@margin}" y1="#{y}" x2="#{@width - @margin}" y2="#{y}" stroke="lightgray" stroke-width="0.5"/>}

      # Label
      svg << %{<text x="#{@margin - 10}" y="#{y + 5}" text-anchor="end" font-size="12">#{value}</text>}
    end

    # Draw bars
    data.each_with_index do |value, i|
      bar_height = (value / max_value.to_f) * @chart_height
      x = @margin + i * bar_width
      y = @height - @margin - bar_height

      # Bar
      svg << %{<rect x="#{x + bar_width * 0.1}" y="#{y}" width="#{bar_width * 0.8}" height="#{bar_height}" fill="#3366CC" opacity="0.8"/>}

      # X-axis label (show every nth label to avoid crowding)
      if i % [labels.length / 10, 1].max == 0 || i == labels.length - 1
        svg << %{<text x="#{x + bar_width / 2}" y="#{@height - @margin + 20}" text-anchor="middle" font-size="10" transform="rotate(-45 #{x + bar_width / 2} #{@height - @margin + 20})">#{labels[i]}</text>}
      end

      # Value on top of bar (for smaller datasets)
      if data.length <= 30
        svg << %{<text x="#{x + bar_width / 2}" y="#{y - 5}" text-anchor="middle" font-size="10">#{value}</text>}
      end
    end

    # Axis labels
    svg << %{<text x="#{@width / 2}" y="#{@height - 10}" text-anchor="middle" font-size="14">#{x_label}</text>}
    svg << %{<text x="20" y="#{@height / 2}" text-anchor="middle" font-size="14" transform="rotate(-90 20 #{@height / 2})">#{y_label}</text>}

    svg << %{</svg>}

    File.write(filename, svg.join("\n"))
    puts "Saved SVG chart to: #{filename}"
  end

  def create_line_chart(x_data, y_data, title: "Line Chart", x_label: "X Axis", y_label: "Y Axis", filename: "line_chart.svg")
    x_min, x_max = x_data.minmax
    y_min, y_max = y_data.minmax

    svg = []
    svg << %{<?xml version="1.0" encoding="UTF-8"?>}
    svg << %{<svg xmlns="http://www.w3.org/2000/svg" width="#{@width}" height="#{@height}">}

    # Background
    svg << %{<rect width="#{@width}" height="#{@height}" fill="white"/>}

    # Title
    svg << %{<text x="#{@width / 2}" y="30" text-anchor="middle" font-size="20" font-weight="bold">#{title}</text>}

    # Draw axes
    svg << %{<line x1="#{@margin}" y1="#{@height - @margin}" x2="#{@width - @margin}" y2="#{@height - @margin}" stroke="black" stroke-width="2"/>}
    svg << %{<line x1="#{@margin}" y1="#{@margin}" x2="#{@margin}" y2="#{@height - @margin}" stroke="black" stroke-width="2"/>}

    # Grid lines and labels
    grid_lines = 10
    (0..grid_lines).each do |i|
      # Y-axis
      y = @height - @margin - (i * @chart_height / grid_lines)
      y_value = y_min + (i * (y_max - y_min) / grid_lines.to_f)
      svg << %{<line x1="#{@margin}" y1="#{y}" x2="#{@width - @margin}" y2="#{y}" stroke="lightgray" stroke-width="0.5"/>}
      svg << %{<text x="#{@margin - 10}" y="#{y + 5}" text-anchor="end" font-size="12">#{y_value.round(1)}</text>}

      # X-axis
      x = @margin + (i * @chart_width / grid_lines)
      x_value = x_min + (i * (x_max - x_min) / grid_lines.to_f)
      svg << %{<line x1="#{x}" y1="#{@margin}" x2="#{x}" y2="#{@height - @margin}" stroke="lightgray" stroke-width="0.5"/>}
      svg << %{<text x="#{x}" y="#{@height - @margin + 20}" text-anchor="middle" font-size="10">#{x_value.round(0)}</text>}
    end

    # Plot line
    points = []
    x_data.zip(y_data).each do |x, y|
      x_pixel = @margin + ((x - x_min) / (x_max - x_min).to_f) * @chart_width
      y_pixel = @height - @margin - ((y - y_min) / (y_max - y_min).to_f) * @chart_height
      points << "#{x_pixel},#{y_pixel}"
    end

    svg << %{<polyline points="#{points.join(" ")}" fill="none" stroke="#3366CC" stroke-width="2"/>}

    # Axis labels
    svg << %{<text x="#{@width / 2}" y="#{@height - 10}" text-anchor="middle" font-size="14">#{x_label}</text>}
    svg << %{<text x="20" y="#{@height / 2}" text-anchor="middle" font-size="14" transform="rotate(-90 20 #{@height / 2})">#{y_label}</text>}

    svg << %{</svg>}

    File.write(filename, svg.join("\n"))
    puts "Saved SVG chart to: #{filename}"
  end
end

# Create histogram data
def create_histogram_data(latencies, num_buckets = 20)
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

    # Create readable labels
    label = if end_val < 1000
      "#{end_val.round(0)}ms"
    else
      "#{(end_val / 1000).round(1)}s"
    end

    bucket_labels << label
  end

  [buckets, bucket_labels]
end

# Generate SVG histogram
puts "Generating SVG histogram..."
buckets, labels = create_histogram_data(latencies, 25)

chart = SVGChart.new(width: 1000, height: 600)
chart.create_histogram(
  buckets,
  labels,
  title: "Latency Distribution (#{num_requests} requests)",
  x_label: "Latency",
  y_label: "Number of Requests",
  filename: "experiments/latency_histogram.svg",
)

# Generate cumulative distribution
puts "Generating cumulative distribution chart..."
cumulative_x = []
cumulative_y = []

# Sample points for CDF (every 10th point to avoid too many points)
sorted_latencies.each_with_index do |latency, i|
  if i % 10 == 0 || i == sorted_latencies.length - 1
    cumulative_x << latency
    cumulative_y << ((i + 1) * 100.0 / sorted_latencies.size)
  end
end

chart.create_line_chart(
  cumulative_x,
  cumulative_y,
  title: "Cumulative Latency Distribution",
  x_label: "Latency (ms)",
  y_label: "Percentile (%)",
  filename: "experiments/latency_cdf.svg",
)

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
puts "Generated 2 SVG charts:"
puts "1. experiments/latency_histogram.svg - Histogram of latency distribution"
puts "2. experiments/latency_cdf.svg - Cumulative distribution function"
puts "\nYou can open these SVG files in any web browser to view the graphs."
