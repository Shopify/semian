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
  error_rate: 0.01, # 1% baseline error rate
  timeout: 5, # 5 seconds timeout
semian: {
    adaptive_circuit_breaker: true,  # Use adaptive circuit breaker instead of traditional
    bulkhead: false,
  },
)

outcomes = {}
done = false
circuit_opened_at_rate = nil
outcomes_mutex = Mutex.new

num_threads = 60
puts "Starting #{num_threads} concurrent request threads (50 requests/second each = 3000 rps total)..."

request_threads = []
num_threads.times do |thread_id|
  request_threads << Thread.new do
    until done
      sleep(0.02) # Each thread: 50 requests per second
      
      begin
        resource.request(rand(resource.endpoints_count))
        
        outcomes_mutex.synchronize do
          current_sec = outcomes[Time.now.to_i] ||= {
            success: 0,
            circuit_open: 0,
            error: 0,
          }
          print "✓"
          current_sec[:success] += 1
        end
        
      rescue Semian::Experiments::ExperimentalResource::CircuitOpenError => e
        outcomes_mutex.synchronize do
          current_sec = outcomes[Time.now.to_i] ||= {
            success: 0,
            circuit_open: 0,
            error: 0,
          }
          print "⚡"
          current_sec[:circuit_open] += 1
        end
        
      rescue Semian::Experiments::ExperimentalResource::RequestError, Semian::Experiments::ExperimentalResource::TimeoutError => e
        outcomes_mutex.synchronize do
          current_sec = outcomes[Time.now.to_i] ||= {
            success: 0,
            circuit_open: 0,
            error: 0,
          }
          print "✗"
          current_sec[:error] += 1
        end
      end
    end
  end
end

# Gradual error rate increase: 1% -> 6% in 0.5% increments
error_rates = (1.0..6.0).step(0.5).to_a
phase_duration = 20 # seconds per phase
phase_metrics = []

puts "\n=== Gradual Error Rate Increase Test (ADAPTIVE) ==="
puts "Starting at 1%, increasing by 0.5% every #{phase_duration} seconds until 6%"
puts "Total test duration: #{error_rates.length * phase_duration} seconds (#{error_rates.length} phases)\n"

error_rates.each_with_index do |rate, index|
  rate_percent = rate / 100.0
  puts "\n--- Phase #{index + 1}: Error rate = #{rate}% ---"
  resource.set_error_rate(rate_percent)
  
  phase_start = Time.now.to_i
  
  # Give it a moment to make sure at least one request has been made
  sleep 1 if index == 0
  
  sleep phase_duration
  
  # Get reference to the circuit breaker's PID controller (after first request has been made)
  begin
    semian_resource = Semian["protected_service_adaptive".to_sym]
    if semian_resource && semian_resource.circuit_breaker
      # Capture PID controller metrics at end of phase
      metrics = semian_resource.circuit_breaker.pid_controller.metrics
      phase_metrics << {
        phase: index + 1,
        error_rate: rate,
        metrics: metrics
      }
    end
  rescue => e
    # If we can't get metrics, that's okay, continue
    puts "Warning: Could not capture metrics - #{e.message}"
  end
  
  # Check if circuit opened during this phase
  if circuit_opened_at_rate.nil?
    phase_data = outcomes.select { |time, _| time >= phase_start && time < phase_start + phase_duration }
    circuit_opens = phase_data.values.sum { |d| d[:circuit_open] }
    if circuit_opens > 0 && circuit_opened_at_rate.nil?
      circuit_opened_at_rate = rate
      puts "🔴 Circuit breaker started rejecting at #{rate}% error rate!"
    end
  end
end

done = true
puts "\nWaiting for all request threads to finish..."
request_threads.each(&:join)

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
  puts "\n🔴 Adaptive circuit breaker started rejecting at: #{circuit_opened_at_rate}% error rate"
else
  puts "\n🟢 Adaptive circuit breaker never rejected during this test"
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
  rejection_pct = phase_total > 0 ? ((phase_circuit.to_f / phase_total) * 100).round(2) : 0
  
  status = phase_circuit > 0 ? "⚡ REJECTING (#{rejection_pct}%)" : "✓"
  puts "Phase #{index + 1} (#{rate}%): #{status}"
  puts "  Requests: #{phase_total} | Success: #{phase_success} | Errors: #{phase_errors} (#{actual_error_pct}%) | Rejected: #{phase_circuit}"
end

# Display PID controller calculations
if !phase_metrics.empty?
  puts "\n=== PID Controller Calculations by Phase ==="
  puts "Legend: P=Proportional, I=Integral, D=Derivative, Health=P term"
  puts "Rejection Rate is calculated as: rejection_rate + (kp*P + ki*I + kd*D)"
  puts "-" * 120
  phase_metrics.each do |pm|
  m = pm[:metrics]
  
  # Calculate the individual terms
  kp = 1.0
  ki = 0.1
  kd = 0.01
  
  health_p = m[:health_metric]
  p_term = kp * health_p
  i_term = ki * m[:integral]
  # D term is calculated during update: kd * (current_error - previous_error) / dt
  # We can approximate it from the previous_error stored
  d_term_approx = kd * m[:previous_error]
  
  puts "\nPhase #{pm[:phase]} (#{pm[:error_rate]}%):"
  puts "  Current Error Rate: #{(m[:error_rate] * 100).round(3)}%"
  puts "  Ideal Error Rate: #{(m[:ideal_error_rate] * 100).round(3)}%"
  puts "  Ping Failure Rate: #{(m[:ping_failure_rate] * 100).round(3)}%"
  puts "  Health Metric (P): #{health_p.round(4)}"
  puts "  Integral (I): #{m[:integral].round(4)}"
  puts "  Previous Error: #{m[:previous_error].round(4)}"
  puts "  ---"
  puts "  P term (kp × P): #{p_term.round(4)}"
  puts "  I term (ki × I): #{i_term.round(4)}"
  puts "  D term (approx): #{d_term_approx.round(4)}"
  puts "  → Rejection Rate: #{(m[:rejection_rate] * 100).round(2)}%"
  end
else
  puts "\n⚠️  No PID metrics collected (resource may not have been registered)"
end

puts "\nGenerating visualization..."

require "gruff"

graph = Gruff::Line.new(1400)
graph.title = "Adaptive Circuit Breaker: Gradual Error Increase (1% → 6%)"
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
graph.data("Rejected", bucketed_data.map { |d| d[:circuit_open] })
graph.data("Error", bucketed_data.map { |d| d[:error] })

graph.write("gradual_error_increase_adaptive.png")

puts "Graph saved to gradual_error_increase_adaptive.png"

