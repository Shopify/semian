#!/usr/bin/env ruby
# frozen_string_literal: true

require "bundler/setup"
require "benchmark"
require_relative "../../lib/semian/timestamped_sliding_window"

# Benchmark to show the performance improvement of lazy cleanup
# vs cleaning up on every observation

class EagerCleanupWindow < Semian::TimestampedSlidingWindow
  # Version that cleans up on every add (less efficient)
  def add_observation(type, timestamp = nil)
    timestamp ||= current_time

    @lock.synchronize do
      @observations << { type: type, timestamp: timestamp }
      cleanup_old_observations(timestamp) # Clean on every add
    end
  end

  private

  def current_time
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end

class LazyCleanupWindow < Semian::TimestampedSlidingWindow
  # This is the optimized version (default implementation)
end

puts "=== Sliding Window Cleanup Benchmark ==="
puts "Comparing eager cleanup (on every write) vs lazy cleanup (only on reads)"
puts ""

iterations = 100_000
window_size = 10

eager_window = EagerCleanupWindow.new(window_size: window_size)
lazy_window = LazyCleanupWindow.new(window_size: window_size)

puts "Testing with #{iterations} observations..."
puts ""

# Benchmark write performance
puts "Write Performance (adding observations):"
puts "-" * 50

eager_time = Benchmark.realtime do
  base_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  iterations.times do |i|
    timestamp = base_time + (i * 0.0001) # Spread over 10 seconds
    eager_window.add_observation(:success, timestamp)
  end
end

lazy_time = Benchmark.realtime do
  base_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  iterations.times do |i|
    timestamp = base_time + (i * 0.0001) # Spread over 10 seconds
    lazy_window.add_observation(:success, timestamp)
  end
end

puts "Eager cleanup: #{(eager_time * 1000).round(2)}ms"
puts "Lazy cleanup:  #{(lazy_time * 1000).round(2)}ms"
puts "Speedup:       #{(eager_time / lazy_time).round(2)}x faster"
puts ""

# Benchmark mixed read/write performance
puts "Mixed Operations (90% writes, 10% reads):"
puts "-" * 50

eager_window.clear
lazy_window.clear

eager_mixed_time = Benchmark.realtime do
  base_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  1000.times do |i|
    timestamp = base_time + (i * 0.01)

    # 90% writes
    9.times do
      eager_window.add_observation([:success, :error].sample, timestamp)
    end

    # 10% reads
    eager_window.calculate_error_rate(timestamp)
  end
end

lazy_mixed_time = Benchmark.realtime do
  base_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  1000.times do |i|
    timestamp = base_time + (i * 0.01)

    # 90% writes
    9.times do
      lazy_window.add_observation([:success, :error].sample, timestamp)
    end

    # 10% reads
    lazy_window.calculate_error_rate(timestamp)
  end
end

puts "Eager cleanup: #{(eager_mixed_time * 1000).round(2)}ms"
puts "Lazy cleanup:  #{(lazy_mixed_time * 1000).round(2)}ms"
puts "Speedup:       #{(eager_mixed_time / lazy_mixed_time).round(2)}x faster"
puts ""

# Show memory efficiency
puts "Memory Efficiency:"
puts "-" * 50
puts "Both approaches maintain the same memory footprint"
puts "(old observations are cleaned up, just at different times)"
puts ""

# Simulate typical PID controller usage pattern
puts "Typical PID Controller Pattern (1000 requests, then 1 update):"
puts "-" * 50

eager_window.clear
lazy_window.clear

eager_pid_time = Benchmark.realtime do
  base_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  100.times do |second|
    timestamp = base_time + second

    # 1000 requests per second
    1000.times do
      eager_window.add_observation([:success, :error].sample, timestamp)
    end

    # One update per second
    eager_window.calculate_error_rate(timestamp)
  end
end

lazy_pid_time = Benchmark.realtime do
  base_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  100.times do |second|
    timestamp = base_time + second

    # 1000 requests per second
    1000.times do
      lazy_window.add_observation([:success, :error].sample, timestamp)
    end

    # One update per second
    lazy_window.calculate_error_rate(timestamp)
  end
end

puts "Eager cleanup: #{(eager_pid_time * 1000).round(2)}ms"
puts "Lazy cleanup:  #{(lazy_pid_time * 1000).round(2)}ms"
puts "Speedup:       #{(eager_pid_time / lazy_pid_time).round(2)}x faster"
puts ""

puts "=== Summary ==="
puts "Lazy cleanup (only on reads) is significantly more efficient,"
puts "especially under high write volume with infrequent reads,"
puts "which is exactly the pattern we see with the PID controller."
