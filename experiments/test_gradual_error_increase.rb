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
  error_rate: 0.01, # 1% baseline error rate
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
circuit_opened_at_rate = nil

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

# Gradual error rate increase: 1% -> 6% in 0.5% increments
error_rates = (1.0..6.0).step(0.5).to_a
phase_duration = 20 # seconds per phase

puts "\n=== Gradual Error Rate Increase Test ==="
puts "Starting at 1%, increasing by 0.5% every #{phase_duration} seconds until 6%"
puts "Total test duration: #{error_rates.length * phase_duration} seconds (#{error_rates.length} phases)\n"

error_rates.each_with_index do |rate, index|
  rate_percent = rate / 100.0
  puts "\n--- Phase #{index + 1}: Error rate = #{rate}% ---"
  resource.set_error_rate(rate_percent)
  
  phase_start = Time.now.to_i
  sleep phase_duration
  
  # Check if circuit opened during this phase
  if circuit_opened_at_rate.nil?
    phase_data = outcomes.select { |time, _| time >= phase_start && time < phase_start + phase_duration }
    circuit_opens = phase_data.values.sum { |d| d[:circuit_open] }
    if circuit_opens > 0 && circuit_opened_at_rate.nil?
      circuit_opened_at_rate = rate
      puts "🔴 Circuit breaker opened at #{rate}% error rate!"
    end
  end
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

if circuit_opened_at_rate
  puts "\n🔴 Circuit breaker opened at: #{circuit_opened_at_rate}% error rate"
else
  puts "\n🟢 Circuit breaker never opened during this test"
end

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
  
  status = phase_circuit > 0 ? "⚡ CIRCUIT OPEN" : "✓"
  puts "Phase #{index + 1} (#{rate}%): #{status}"
  puts "  Requests: #{phase_total} | Success: #{phase_success} | Errors: #{phase_errors} (#{actual_error_pct}%) | Circuit: #{phase_circuit}"
end

puts "\nGenerating visualization..."

require "gruff"

graph = Gruff::Line.new(1400)
graph.title = "Circuit Breaker: Gradual Error Increase (1% → 6%)"
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

# Set x-axis labels to show error rates
graph.labels = error_rates.each_with_index.to_h { |rate, i| [i, "#{rate}%"] }

graph.data("Success", bucketed_data.map { |d| d[:success] })
graph.data("Circuit Open", bucketed_data.map { |d| d[:circuit_open] })
graph.data("Error", bucketed_data.map { |d| d[:error] })

graph.write("gradual_error_increase.png")

puts "Graph saved to gradual_error_increase.png"

