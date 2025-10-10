# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "semian"
require_relative "experimental_resource"

puts "Creating experimental resource with circuit breaker..."
resource = Semian::Experiments::ExperimentalResource.new(
  name: "protected_service",
  endpoints_count: 200,
  min_latency: 0.01,
  max_latency: 10,
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

puts "Starting request thread (50 requests/second for higher volume)..."
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

puts "\n=== Phase 1: Normal operation (1% error rate) ==="
puts "Running for 10 seconds...\n"
sleep 10

puts "\n\n=== Phase 2: Moderate error spike (20% error rate) ==="
puts "Increasing error rate to 20%...\n"
resource.set_error_rate(0.20)
sleep 15

puts "\n\n=== Phase 3: Recovery (back to 1% error rate) ==="
puts "Resetting error rate to 1%...\n"
resource.set_error_rate(0.01)
sleep 15

done = true
sleep 0.5 # Give the thread time to finish

puts "\n\n=== Test Complete ==="
puts "\nGenerating visualization..."

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

# Phase breakdown
phase1_data = outcomes.select { |time, _| time < outcomes.keys[0] + 10 }
phase2_data = outcomes.select { |time, _| time >= outcomes.keys[0] + 10 && time < outcomes.keys[0] + 25 }
phase3_data = outcomes.select { |time, _| time >= outcomes.keys[0] + 25 }

puts "\n=== Phase Breakdown ==="
puts "Phase 1 (1% error rate):"
phase1_total = phase1_data.values.sum { |d| d[:success] + d[:circuit_open] + d[:error] }
phase1_errors = phase1_data.values.sum { |d| d[:error] }
puts "  Total: #{phase1_total}, Errors: #{phase1_errors} (#{(phase1_errors.to_f / phase1_total * 100).round(2)}%)"

puts "Phase 2 (20% error rate):"
phase2_total = phase2_data.values.sum { |d| d[:success] + d[:circuit_open] + d[:error] }
phase2_errors = phase2_data.values.sum { |d| d[:error] }
phase2_circuit = phase2_data.values.sum { |d| d[:circuit_open] }
puts "  Total: #{phase2_total}, Errors: #{phase2_errors}, Circuit Opens: #{phase2_circuit}"

puts "Phase 3 (1% error rate - recovery):"
phase3_total = phase3_data.values.sum { |d| d[:success] + d[:circuit_open] + d[:error] }
phase3_errors = phase3_data.values.sum { |d| d[:error] }
phase3_circuit = phase3_data.values.sum { |d| d[:circuit_open] }
puts "  Total: #{phase3_total}, Errors: #{phase3_errors}, Circuit Opens: #{phase3_circuit}"

require "gruff"

graph = Gruff::Line.new(1200)
graph.title = "Circuit Breaker: 1% → 20% Error Spike (High Volume)"
graph.x_axis_label = "Time (seconds)"
graph.y_axis_label = "Requests per Second"

graph.hide_dots = true
graph.line_width = 3

graph.data("Success", outcomes.map { |_, data| data[:success] })
graph.data("Circuit Open", outcomes.map { |_, data| data[:circuit_open] })
graph.data("Error", outcomes.map { |_, data| data[:error] })

graph.write("moderate_error_spike_high_volume.png")

puts "\nGraph saved to moderate_error_spike_high_volume.png"

