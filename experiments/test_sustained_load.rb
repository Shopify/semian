# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "semian"
require_relative "mock_service"
require_relative "experimental_resource"

puts "Creating mock service..."
# Create a single shared mock service instance
service = Semian::Experiments::MockService.new(
  endpoints_count: 50,
  min_latency: 0.01,
  max_latency: 0.3,
  distribution: {
    type: :log_normal,
    mean: 0.15,
    std_dev: 0.05,
  },
  error_rate: 0.01, # Starting at 1% error rate
  timeout: 5, # 5 seconds timeout
)

# Semian configuration
semian_config = {
  success_threshold: 2,
  error_threshold: 3,
  error_threshold_timeout: 20,
  error_timeout: 15,
  bulkhead: false,
}

# Initialize Semian resource before threading to avoid race conditions
puts "Initializing Semian resource..."
begin
  init_resource = Semian::Experiments::ExperimentalResource.new(
    name: "protected_service",
    service: service,
    semian: semian_config
  )
  init_resource.request(0) # Make one request to trigger registration
rescue
  # Ignore any error, we just needed to trigger registration
end
puts "Resource initialized successfully.\n"

outcomes = {}
done = false
outcomes_mutex = Mutex.new

num_threads = 60
puts "Starting #{num_threads} concurrent request threads (50 requests/second each = 3000 rps total)..."
puts "Each thread will have its own adapter instance connected to the shared service...\n"

request_threads = []
num_threads.times do |_|
  request_threads << Thread.new do
    # Each thread creates its own adapter instance that wraps the shared service
    # They share the same Semian circuit breaker via the name
    thread_resource = Semian::Experiments::ExperimentalResource.new(
      name: "protected_service",
      service: service,
      semian: semian_config
    )

    until done
      sleep(0.02) # Each thread: 50 requests per second

      begin
        thread_resource.request(rand(service.endpoints_count))

        outcomes_mutex.synchronize do
          current_sec = outcomes[Time.now.to_i] ||= {
            success: 0,
            circuit_open: 0,
            error: 0,
          }
          print("✓")
          current_sec[:success] += 1
        end
      rescue Semian::Experiments::ExperimentalResource::CircuitOpenError
        outcomes_mutex.synchronize do
          current_sec = outcomes[Time.now.to_i] ||= {
            success: 0,
            circuit_open: 0,
            error: 0,
          }
          print("⚡")
          current_sec[:circuit_open] += 1
        end
      rescue Semian::Experiments::ExperimentalResource::RequestError, Semian::Experiments::ExperimentalResource::TimeoutError
        outcomes_mutex.synchronize do
          current_sec = outcomes[Time.now.to_i] ||= {
            success: 0,
            circuit_open: 0,
            error: 0,
          }
          print("✗")
          current_sec[:error] += 1
        end
      end
    end
  end
end

test_duration = 540 # 9 minutes total

puts "\n=== Sustained Load Test (CLASSIC) ==="
puts "Phase 1: Baseline 1% error rate (2 minutes)"
puts "Phase 2: High 20% error rate (5 minutes)"
puts "Phase 3: Return to baseline 1% error rate (2 minutes)"
puts "Total Duration: #{test_duration} seconds"
puts "Starting test...\n"

start_time = Time.now
sleep 120

# Update error rate on the shared service
service.set_error_rate(0.20)

sleep 300

# Reset error rate on the shared service
service.set_error_rate(0.01)

sleep 120

done = true
puts "\nWaiting for all request threads to finish..."
request_threads.each(&:join)
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
puts "\nExpected errors at 20% rate: #{(total_requests * 0.20).round(0)}"
puts "Actual errors: #{total_error}"
puts "Difference: #{total_error - (total_requests * 0.20).round(0)}"

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

  puts "#{status} #{bucket_time_range}: #{bucket_total} requests | Success: #{bucket_success} | Errors: #{bucket_errors} (#{error_pct}%) | Circuit Open: #{bucket_circuit} (#{circuit_pct}%)"
end

# Calculate circuit breaker efficiency
expected_errors = (total_requests * 0.20).round(0)
actual_errors = total_error
error_difference = actual_errors - expected_errors

puts "\n=== Classic Circuit Breaker Impact ==="
puts "Expected errors without circuit breaker: #{expected_errors}"
puts "Actual errors with circuit breaker: #{actual_errors}"
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
graph.title = "Classic Circuit Breaker: Sustained 20% Error Load"
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
    error: bucket_data.values.sum { |d| d[:error] },
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

graph.write("sustained_load.png")

puts "Graph saved to sustained_load.png"
