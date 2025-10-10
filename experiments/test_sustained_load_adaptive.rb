# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "semian"
require_relative "experimental_resource"

puts "Creating experimental resource with ADAPTIVE circuit breaker..."
resource = Semian::Experiments::ExperimentalResource.new(
  name: "protected_service_adaptive",
  endpoints_count: 50,
  min_latency: 0.01,
  max_latency: 0.2,
  distribution: {
    type: :log_normal,
    mean: 1,
    std_dev: 0.1,
  },
  error_rate: 0.06, # 6% sustained error rate
  timeout: 5, # 5 seconds timeout
  semian: {
    adaptive_circuit_breaker: true,  # Use adaptive circuit breaker
    bulkhead: false,
  },
)

outcomes = {}
done = false
circuit_state_changes = []

puts "Starting request thread (50 requests/second)..."
Thread.new do
  until done
    sleep(0.02) # 50 requests per second
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

puts "\n=== Sustained Load Test (ADAPTIVE) ==="
puts "Error rate: 6%"
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
puts "  Rejected: #{total_circuit_open} (#{(total_circuit_open.to_f / total_requests * 100).round(2)}%)"
puts "  Errors: #{total_error} (#{(total_error.to_f / total_requests * 100).round(2)}%)"
puts "\nExpected errors at 6% rate: #{(total_requests * 0.06).round(0)}"
puts "Actual errors: #{total_error}"
puts "Difference: #{total_error - (total_requests * 0.06).round(0)}"

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
  circuit_pct = bucket_total > 0 ? ((bucket_circuit.to_f / bucket_total) * 100).round(2) : 0
  error_pct = bucket_total > 0 ? ((bucket_errors.to_f / bucket_total) * 100).round(2) : 0
  status = bucket_circuit > 0 ? "⚡" : "✓"
  
  puts "#{status} #{bucket_time_range}: #{bucket_total} requests | Success: #{bucket_success} | Errors: #{bucket_errors} (#{error_pct}%) | Rejected: #{bucket_circuit} (#{circuit_pct}%)"
end

# Get PID controller metrics if available
begin
  semian_resource = Semian["protected_service_adaptive".to_sym]
  if semian_resource && semian_resource.circuit_breaker
    pid_metrics = semian_resource.circuit_breaker.pid_controller.metrics
    
    puts "\n=== PID Controller Final State ==="
    puts "Current Error Rate: #{(pid_metrics[:error_rate] * 100).round(3)}%"
    puts "Ideal Error Rate (p90): #{(pid_metrics[:ideal_error_rate] * 100).round(3)}%"
    puts "Ping Failure Rate: #{(pid_metrics[:ping_failure_rate] * 100).round(3)}%"
    puts "Health Metric: #{pid_metrics[:health_metric].round(4)}"
    puts "Rejection Rate: #{(pid_metrics[:rejection_rate] * 100).round(2)}%"
    puts "Integral: #{pid_metrics[:integral].round(4)}"
  end
rescue => e
  puts "\n⚠️  Could not capture PID metrics: #{e.message}"
end

# Calculate circuit breaker efficiency
expected_errors = (total_requests * 0.06).round(0)
actual_errors = total_error
error_difference = actual_errors - expected_errors

puts "\n=== Adaptive Circuit Breaker Impact ==="
puts "Expected errors without circuit breaker: #{expected_errors}"
puts "Actual errors with adaptive circuit breaker: #{actual_errors}"
if error_difference > 0
  puts "Extra errors allowed through: #{error_difference}"
  puts "Rejection efficiency: #{((1 - error_difference.to_f / expected_errors) * 100).round(2)}%"
else
  puts "Errors prevented: #{-error_difference}"
  puts "Protection efficiency: #{((-error_difference.to_f / expected_errors) * 100).round(2)}%"
end

puts "\nGenerating visualization..."

require "gruff"

# Create line graph showing requests per 10-second bucket
graph = Gruff::Line.new(1400)
graph.title = "Adaptive Circuit Breaker: Sustained 6% Error Load (3 minutes)"
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
graph.data("Rejected", bucketed_data.map { |d| d[:circuit_open] })
graph.data("Error", bucketed_data.map { |d| d[:error] })

graph.write("sustained_load_adaptive.png")

puts "Graph saved to sustained_load_adaptive.png"

