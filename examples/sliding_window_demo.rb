#!/usr/bin/env ruby
# frozen_string_literal: true

require "bundler/setup"
require_relative "../lib/semian"
require_relative "../lib/semian/adaptive_circuit_breaker"
require_relative "../lib/semian/pid_controller"
require_relative "../lib/semian/timestamped_sliding_window"

# Demo script showing the sliding window implementation
puts "=== Semian Sliding Window Demo ==="
puts "This demonstrates the new sliding window implementation with:"
puts "- 10-second lookback window"
puts "- 1-second sliding updates"
puts "- Automatic removal of old observations\n\n"

# Create a PID controller with sliding window
controller = Semian::PIDController.new(
  kp: 0.75,
  ki: 0.01,
  kd: 0.5,
  window_size: 10, # 10-second lookback window
  initial_history_duration: 900,
  initial_error_rate: 0.01,
)

# Simulate 15 seconds of activity
puts "Simulating 15 seconds of activity..."
puts "Seconds 0-5: Low error rate (1%)"
puts "Seconds 5-10: High error rate (10%)"
puts "Seconds 10-15: Medium error rate (5%)\n\n"

start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

15.times do |second|
  current_time = start_time + second

  # Simulate different error rates in different time periods
  if second < 5
    # Low error rate (1%)
    99.times { controller.record_request(:success, current_time) }
    1.times { controller.record_request(:error, current_time) }
  elsif second < 10
    # High error rate (10%)
    90.times { controller.record_request(:success, current_time) }
    10.times { controller.record_request(:error, current_time) }
  else
    # Medium error rate (5%)
    95.times { controller.record_request(:success, current_time) }
    5.times { controller.record_request(:error, current_time) }
  end

  # Update controller every second (sliding by 1 second)
  if second > 0
    controller.update

    metrics = controller.metrics
    counts = metrics[:current_window_requests]
    total = counts[:success] + counts[:error]
    error_rate = total > 0 ? (counts[:error].to_f / total * 100).round(2) : 0

    puts "Second #{second}:"
    puts "  Window contains: #{total} requests (#{counts[:success]} success, #{counts[:error]} error)"
    puts "  Current error rate: #{error_rate}%"
    puts "  Rejection rate: #{(metrics[:rejection_rate] * 100).round(2)}%"
    puts ""
  end

  # Sleep for a bit to simulate real time passing
  sleep(0.1)
end

puts "\n=== Key Features Demonstrated ==="
puts "1. The window always contains exactly 10 seconds of data"
puts "2. Updates happen every 1 second (sliding amount)"
puts "3. Old observations (>10 seconds) are automatically removed"
puts "4. Error rates are calculated based only on recent data"
puts "5. PID controller adjusts rejection rate based on sliding window metrics"

# Demonstrate the sliding window directly
puts "\n=== Direct Sliding Window Example ==="
window = Semian::TimestampedSlidingWindow.new(window_size: 10)

base_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

# Add observations at different times
puts "Adding observations at t=0..."
window.add_observation(:success, base_time)
window.add_observation(:error, base_time)

puts "Adding observations at t=5..."
window.add_observation(:success, base_time + 5)
window.add_observation(:error, base_time + 5)

puts "Adding observations at t=11 (beyond 10-second window from t=0)..."
window.add_observation(:success, base_time + 11)

# Check what's in the window
counts = window.get_counts(base_time + 11)
puts "\nWindow contents at t=11:"
puts "  Success: #{counts[:success]}"
puts "  Error: #{counts[:error]}"
puts "  Rejected: #{counts[:rejected]}"
puts "\nObservations from t=0 have been automatically removed!"
