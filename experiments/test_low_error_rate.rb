# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "semian"
require_relative "experimental_resource"

puts "Creating experimental resource with circuit breaker..."
resource = Semian::Experiments::ExperimentalResource.new(
  name: "protected_service",
  endpoints_count: 50,
  min_latency: 0.01,
  max_latency: 0.2,
  distribution: {
    type: :log_normal,
    mean: 1,
    std_dev: 0.1,
  },
  error_rate: 0.003, # 0.3% error rate
  timeout: 5, # 5 seconds timeout
  semian: {
    success_threshold: 2,
    error_threshold: 3,
    error_threshold_timeout: 20,
    error_timeout: 15,
    bulkhead: false,
  },
)

outcomes = {}
done = false

puts "Starting request thread (100 requests/second)..."
Thread.new do
  until done
    sleep(0.01) # 100 requests per second
    current_sec = outcomes[Time.now.to_i] ||= {
      success: 0,
      circuit_open: 0,
      error: 0,
    }
    begin
      resource.request(rand(resource.endpoints_count))
      print "✓"
      current_sec[:success] += 1
    rescue Semian::Experiments::ExperimentalResource::CircuitOpenError => e
      print "⚡"
      current_sec[:circuit_open] += 1
    rescue Semian::Experiments::ExperimentalResource::RequestError, Semian::Experiments::ExperimentalResource::TimeoutError => e
      print "✗"
      current_sec[:error] += 1
    end
  end
end

test_duration = 180 # 3 minutes

puts "\n=== Low Error Rate Test ==="
puts "Error rate: 0.3%"
puts "Duration: #{test_duration} seconds (3 minutes)"
puts "Starting test...\n"

start_time = Time.now
sleep test_duration

done = true
sleep 0.5 # Give the thread time to finish
end_time = Time.now

puts "\n\n=== Test Complete ==="
puts "Actual duration: #{(end_time - start_time).round(2)} seconds"
puts "\nGenerating analysis..."

# Calculate summary statistics
total_success = outcomes.values.sum { |data| data[:success] }
total_circuit_open = outcomes.values.sum { |data| data[:circuit_open] }
total_error = outcomes.values.sum { |data| data[:error] }
total_requests = total_success + total_circuit_open + total_error

puts "\n=== Summary Statistics ==="
puts "Total Requests: #{total_requests}"
puts "  Successes: #{total_success} (#{(total_success.to_f / total_requests * 100).round(2)}%)"
puts "  Circuit Open: #{total_circuit_open} (#{(total_circuit_open.to_f / total_requests * 100).round(2)}%)"
puts "  Errors: #{total_error} (#{(total_error.to_f / total_requests * 100).round(2)}%)"
puts "\nExpected errors at 0.3% rate: #{(total_requests * 0.003).round(1)}"
puts "Actual errors: #{total_error}"

# Determine if circuit ever opened
circuit_opened = total_circuit_open > 0

if circuit_opened
  puts "\n⚠️  Circuit breaker opened at least once during the test"
  
  # Find when circuit opened
  first_circuit_open = nil
  outcomes.each do |time, data|
    if data[:circuit_open] > 0
      first_circuit_open = time - outcomes.keys[0]
      break
    end
  end
  puts "First circuit open occurred at: #{first_circuit_open} seconds into the test"
else
  puts "\n✓ Circuit breaker remained closed throughout the entire test"
  puts "With 0.2% error rate, errors were too sparse to trigger the circuit (need 3 errors)"
end

# Time-based analysis (30-second buckets)
bucket_size = 30 # seconds
num_buckets = (test_duration / bucket_size.to_f).ceil

puts "\n=== Time-Based Analysis (#{bucket_size}-second buckets) ==="
(0...num_buckets).each do |bucket_idx|
  bucket_start = outcomes.keys[0] + (bucket_idx * bucket_size)
  bucket_data = outcomes.select { |time, _| time >= bucket_start && time < bucket_start + bucket_size }
  
  bucket_success = bucket_data.values.sum { |d| d[:success] }
  bucket_errors = bucket_data.values.sum { |d| d[:error] }
  bucket_circuit = bucket_data.values.sum { |d| d[:circuit_open] }
  bucket_total = bucket_success + bucket_errors + bucket_circuit
  
  bucket_time_range = "#{bucket_idx * bucket_size}-#{(bucket_idx + 1) * bucket_size}s"
  error_pct = bucket_total > 0 ? ((bucket_errors.to_f / bucket_total) * 100).round(3) : 0
  status = bucket_circuit > 0 ? "⚡" : "✓"
  
  puts "#{status} #{bucket_time_range}: #{bucket_total} requests | Success: #{bucket_success} | Errors: #{bucket_errors} (#{error_pct}%) | Circuit: #{bucket_circuit}"
end

# Calculate overall error rate
actual_error_rate = total_requests > 0 ? ((total_error.to_f / total_requests) * 100).round(3) : 0

puts "\n=== Error Rate Analysis ==="
puts "Expected error rate: 0.3%"
puts "Actual error rate: #{actual_error_rate}%"
puts "Difference: #{(actual_error_rate - 0.3).round(3)}%"

if circuit_opened
  expected_errors = (total_requests * 0.003).round(1)
  prevented_errors = [expected_errors - total_error, 0].max
  efficiency = expected_errors > 0 ? ((prevented_errors.to_f / expected_errors) * 100).round(2) : 0
  
  puts "\n=== Circuit Breaker Impact ==="
  puts "Expected errors without circuit breaker: #{expected_errors}"
  puts "Actual errors with circuit breaker: #{total_error}"
  puts "Errors potentially prevented: #{prevented_errors.round(1)}"
  puts "Protection efficiency: #{efficiency}%"
end

puts "\nGenerating visualization..."

require "gruff"

# Create line graph showing requests per 10-second bucket
graph = Gruff::Line.new(1400)
graph.title = "Circuit Breaker: 0.3% Error Rate (3 minutes)"
graph.x_axis_label = "Time (10-second intervals)"
graph.y_axis_label = "Requests per Interval"

graph.hide_dots = false
graph.line_width = 3

# Aggregate data into 10-second buckets for detailed visualization
small_bucket_size = 10
num_small_buckets = (test_duration / small_bucket_size.to_f).ceil

bucketed_data = []
(0...num_small_buckets).each do |bucket_idx|
  bucket_start = outcomes.keys[0] + (bucket_idx * small_bucket_size)
  bucket_data = outcomes.select { |time, _| time >= bucket_start && time < bucket_start + small_bucket_size }
  
  bucketed_data << {
    success: bucket_data.values.sum { |d| d[:success] },
    circuit_open: bucket_data.values.sum { |d| d[:circuit_open] },
    error: bucket_data.values.sum { |d| d[:error] }
  }
end

# Set x-axis labels (show every 30 seconds for clarity)
labels = {}
(0...num_small_buckets).each do |i|
  time_sec = i * small_bucket_size
  labels[i] = "#{time_sec}s" if time_sec % 30 == 0
end
graph.labels = labels

graph.data("Success", bucketed_data.map { |d| d[:success] })
graph.data("Circuit Open", bucketed_data.map { |d| d[:circuit_open] })
graph.data("Error", bucketed_data.map { |d| d[:error] })

graph.write("low_error_rate.png")

puts "Graph saved to low_error_rate.png"

