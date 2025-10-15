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
  error_rate: 0.02, # Start at 2% error rate
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

# Oscillating error rates: 2% <-> 6% (3 cycles)
error_rates = [2.0, 6.0, 2.0, 6.0, 2.0, 6.0]
phase_duration = 20 # seconds per phase
cycles = 3

puts "\n=== Oscillating Error Rate Test ==="
puts "Oscillating between 2% and 6% error rates"
puts "#{cycles} cycles, #{phase_duration} seconds per phase"
puts "Total test duration: #{error_rates.length * phase_duration} seconds (#{error_rates.length} phases)\n"

error_rates.each_with_index do |rate, index|
  rate_percent = rate / 100.0
  cycle_num = (index / 2) + 1
  phase_type = index.even? ? "LOW" : "HIGH"
  
  puts "\n--- Cycle #{cycle_num}, Phase #{index + 1}: Error rate = #{rate}% (#{phase_type}) ---"
  resource.set_error_rate(rate_percent)
  
  sleep phase_duration
end

done = true
sleep 0.5 # Give the thread time to finish

puts "\n\n=== Test Complete ==="
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

# Phase-by-phase breakdown
puts "\n=== Phase-by-Phase Breakdown ==="
error_rates.each_with_index do |rate, index|
  phase_start_time = outcomes.keys[0] + (index * phase_duration)
  phase_data = outcomes.select { |time, _| time >= phase_start_time && time < phase_start_time + phase_duration }
  
  phase_success = phase_data.values.sum { |d| d[:success] }
  phase_errors = phase_data.values.sum { |d| d[:error] }
  phase_circuit = phase_data.values.sum { |d| d[:circuit_open] }
  phase_total = phase_success + phase_errors + phase_circuit
  
  actual_error_pct = phase_total > 0 ? ((phase_errors.to_f / phase_total) * 100).round(2) : 0
  
  cycle_num = (index / 2) + 1
  phase_type = index.even? ? "LOW" : "HIGH"
  status = phase_circuit > 0 ? "⚡ CIRCUIT OPEN" : "✓"
  
  puts "Cycle #{cycle_num}, Phase #{index + 1} (#{rate}% #{phase_type}): #{status}"
  puts "  Requests: #{phase_total} | Success: #{phase_success} | Errors: #{phase_errors} (#{actual_error_pct}%) | Circuit: #{phase_circuit}"
end

# Cycle-by-cycle comparison
puts "\n=== Cycle-by-Cycle Comparison ==="
(0...cycles).each do |cycle_idx|
  low_phase_idx = cycle_idx * 2
  high_phase_idx = cycle_idx * 2 + 1
  
  low_start = outcomes.keys[0] + (low_phase_idx * phase_duration)
  low_data = outcomes.select { |time, _| time >= low_start && time < low_start + phase_duration }
  low_circuit = low_data.values.sum { |d| d[:circuit_open] }
  low_total = low_data.values.sum { |d| d[:success] + d[:circuit_open] + d[:error] }
  
  high_start = outcomes.keys[0] + (high_phase_idx * phase_duration)
  high_data = outcomes.select { |time, _| time >= high_start && time < high_start + phase_duration }
  high_circuit = high_data.values.sum { |d| d[:circuit_open] }
  high_total = high_data.values.sum { |d| d[:success] + d[:circuit_open] + d[:error] }
  
  low_circuit_pct = low_total > 0 ? ((low_circuit.to_f / low_total) * 100).round(2) : 0
  high_circuit_pct = high_total > 0 ? ((high_circuit.to_f / high_total) * 100).round(2) : 0
  
  puts "Cycle #{cycle_idx + 1}:"
  puts "  2% phase: #{low_circuit} circuit opens (#{low_circuit_pct}% of #{low_total} requests)"
  puts "  6% phase: #{high_circuit} circuit opens (#{high_circuit_pct}% of #{high_total} requests)"
end

puts "\nGenerating visualization..."

require "gruff"

graph = Gruff::Line.new(1400)
graph.title = "Circuit Breaker: Oscillating Errors (2% ↔ 6%)"
graph.x_axis_label = "Time (20-second intervals)"
graph.y_axis_label = "Requests per Interval"

graph.hide_dots = false
graph.line_width = 3

# Aggregate data into 20-second buckets for cleaner visualization
bucketed_data = []
error_rates.each_with_index do |rate, index|
  phase_start_time = outcomes.keys[0] + (index * phase_duration)
  phase_data = outcomes.select { |time, _| time >= phase_start_time && time < phase_start_time + phase_duration }
  
  bucketed_data << {
    success: phase_data.values.sum { |d| d[:success] },
    circuit_open: phase_data.values.sum { |d| d[:circuit_open] },
    error: phase_data.values.sum { |d| d[:error] }
  }
end

# Set x-axis labels to show error rates with cycle indicators
graph.labels = error_rates.each_with_index.to_h do |rate, i|
  cycle = (i / 2) + 1
  [i, "C#{cycle}: #{rate}%"]
end

graph.data("Success", bucketed_data.map { |d| d[:success] })
graph.data("Circuit Open", bucketed_data.map { |d| d[:circuit_open] })
graph.data("Error", bucketed_data.map { |d| d[:error] })

graph.write("oscillating_errors.png")

puts "Graph saved to oscillating_errors.png"

