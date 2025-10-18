#!/usr/bin/env ruby
# frozen_string_literal: true

require "bundler/setup"
require_relative "../lib/semian/adaptive_circuit_breaker"

# Mock dependency that can simulate failures
class MockDependency
  def initialize(failure_rate: 0.0)
    @failure_rate = failure_rate
    @request_count = 0
    @ping_count = 0
  end

  def call
    @request_count += 1
    if rand < @failure_rate
      raise "Dependency failed!"
    end

    "Success"
  end

  def ping
    @ping_count += 1
    if rand < @failure_rate
      raise "Ping failed!"
    end

    "Pong"
  end

  def set_failure_rate(rate)
    @failure_rate = rate
  end

  def stats
    { requests: @request_count, pings: @ping_count }
  end
end

# Demonstration of the adaptive circuit breaker
def main
  puts "=" * 60
  puts "Adaptive Circuit Breaker Demo"
  puts "=" * 60

  # Create dependency and circuit breaker
  dependency = MockDependency.new(failure_rate: 0.0)

  # NOTE: In production, you would use Semian.register with adaptive_circuit_breaker: true
  # This direct instantiation is for demonstration purposes only
  breaker = Semian::AdaptiveCircuitBreaker.new(
    name: "demo_breaker",
  )

  puts "\nPhase 1: Healthy dependency (0% failure rate)"
  puts "-" * 40
  5.times do |i|
    result = breaker.acquire(dependency) { dependency.call }
    puts "Request #{i + 1}: #{result}"
  rescue => e
    puts "Request #{i + 1}: #{e.message}"
  end

  sleep(1) # Let background pings run
  metrics = breaker.metrics
  puts "\nMetrics after healthy phase:"
  puts "  Rejection rate: #{(metrics[:rejection_rate] * 100).round(2)}%"
  puts "  Error rate: #{(metrics[:error_rate] * 100).round(2)}%"
  puts "  Ping failure rate: #{(metrics[:ping_failure_rate] * 100).round(2)}%"
  puts "  Health metric P: #{metrics[:health_metric].round(3)}"

  puts "\nPhase 2: Dependency starts failing (80% failure rate)"
  puts "-" * 40
  dependency.set_failure_rate(0.8)

  10.times do |i|
    result = breaker.acquire(dependency) { dependency.call }
    puts "Request #{i + 1}: #{result}"
  rescue Semian::OpenCircuitError => e
    puts "Request #{i + 1}: REJECTED - #{e.message}"
  rescue => e
    puts "Request #{i + 1}: ERROR - #{e.message}"
  end

  sleep(1) # Let background pings detect failures
  metrics = breaker.metrics
  puts "\nMetrics after failure phase:"
  puts "  Rejection rate: #{(metrics[:rejection_rate] * 100).round(2)}%"
  puts "  Error rate: #{(metrics[:error_rate] * 100).round(2)}%"
  puts "  Ping failure rate: #{(metrics[:ping_failure_rate] * 100).round(2)}%"
  puts "  Health metric P: #{metrics[:health_metric].round(3)}"

  puts "\nNote: High ping failure rate drives rejection rate up"
  puts "Formula: P = (error_rate - ideal) - (rejection - ping_failure)"

  puts "\nPhase 3: Dependency recovers (0% failure rate)"
  puts "-" * 40
  dependency.set_failure_rate(0.0)

  # Background pings will detect recovery
  sleep(2)

  10.times do |i|
    result = breaker.acquire(dependency) { dependency.call }
    puts "Request #{i + 1}: #{result}"
  rescue Semian::OpenCircuitError => e
    puts "Request #{i + 1}: REJECTED - #{e.message}"
  rescue => e
    puts "Request #{i + 1}: ERROR - #{e.message}"
  end

  metrics = breaker.metrics
  puts "\nMetrics after recovery phase:"
  puts "  Rejection rate: #{(metrics[:rejection_rate] * 100).round(2)}%"
  puts "  Error rate: #{(metrics[:error_rate] * 100).round(2)}%"
  puts "  Ping failure rate: #{(metrics[:ping_failure_rate] * 100).round(2)}%"
  puts "  Health metric P: #{metrics[:health_metric].round(3)}"

  puts "\nNote: Successful pings help reduce rejection rate"

  puts "\nDependency stats:"
  puts "  #{dependency.stats}"
  puts "\nNotice: Pings continue even during rejections (out-of-band)!"

  # Clean up
  breaker.stop

  puts "\n" + "=" * 60
  puts "Demo complete!"
  puts "=" * 60
end

main if __FILE__ == $0
