#!/usr/bin/env ruby
# frozen_string_literal: true

require "bundler/setup"
require "semian"
require "semian/net_http"
require "net/http"

# Example: Dual Circuit Breaker with Net::HTTP
# This shows how to run both legacy and adaptive circuit breakers in parallel
# and switch between them at runtime using a feature flag.

# Simulate a feature flag system (in production, this would be your actual feature flag service)
module ExperimentFlags
  @enabled = false

  def self.enable_adaptive!
    @enabled = true
  end

  def self.disable_adaptive!
    @enabled = false
  end

  def self.use_adaptive_circuit_breaker?
    @enabled
  end
end

# Configure Semian with dual circuit breaker
Semian::NetHTTP.semian_configuration = proc do |host, port|
  # Example: only enable for specific host
  if host == "example.com"
    {
      # Enable dual circuit breaker mode
      dual_circuit_breaker: true,

      # Experiment flag proc - checked at each request
      experiment_flag_proc: -> { ExperimentFlags.use_adaptive_circuit_breaker? },

      # Legacy circuit breaker settings (required)
      success_threshold: 2,
      error_threshold: 3,
      error_timeout: 5,

      # Adaptive circuit breaker settings (uses defaults if not specified)
      seed_error_rate: 0.01,

      # Bulkhead settings
      tickets: 3,
      timeout: 1,

      # Exceptions to track
      exceptions: [Net::HTTPServerException],
    }
  end
end

puts "=== Dual Circuit Breaker with Net::HTTP ===\n\n"

# Helper to make HTTP requests
def make_request(uri_str)
  uri = URI(uri_str)
  Net::HTTP.start(uri.host, uri.port) do |http|
    request = Net::HTTP::Get.new(uri)
    response = http.request(request)
    response.code
  end
rescue => e
  e.class.name
end

# Phase 1: Use legacy circuit breaker
puts "Phase 1: Using LEGACY circuit breaker"
puts "-" * 50
ExperimentFlags.disable_adaptive!

3.times do |i|
  puts "Request #{i + 1} (using legacy)..."
  result = make_request("http://example.com/")
  puts "  Result: #{result}\n\n"
  sleep 0.5
end

# Get the resource and check metrics
resource = Semian[:net_http_example_com_80]
if resource && resource.circuit_breaker.respond_to?(:metrics)
  metrics = resource.circuit_breaker.metrics
  puts "Metrics after Phase 1:"
  puts "  Active: #{metrics[:active]}"
  puts "  Legacy state: #{metrics[:legacy][:state]}\n\n"
end

# Phase 2: Switch to adaptive circuit breaker
puts "Phase 2: Switching to ADAPTIVE circuit breaker"
puts "-" * 50
ExperimentFlags.enable_adaptive!

3.times do |i|
  puts "Request #{i + 1} (using adaptive)..."
  result = make_request("http://example.com/")
  puts "  Result: #{result}\n\n"
  sleep 0.5
end

if resource && resource.circuit_breaker.respond_to?(:metrics)
  metrics = resource.circuit_breaker.metrics
  puts "Metrics after Phase 2:"
  puts "  Active: #{metrics[:active]}"
  puts "  Adaptive rejection_rate: #{metrics[:adaptive][:rejection_rate]}\n\n"
end

# Phase 3: Demonstrate dynamic switching
puts "Phase 3: Dynamic switching during runtime"
puts "-" * 50

5.times do |i|
  # Toggle between legacy and adaptive
  if i.even?
    ExperimentFlags.disable_adaptive!
    active = "LEGACY"
  else
    ExperimentFlags.enable_adaptive!
    active = "ADAPTIVE"
  end

  puts "Request #{i + 1} (using #{active})..."
  result = make_request("http://example.com/")
  puts "  Result: #{result}\n\n"
  sleep 0.3
end

puts "=== Demo Complete ===\n\n"
puts "Key Benefits of Dual Circuit Breaker:"
puts "  1. Both breakers track all requests independently"
puts "  2. Can switch between breakers without losing state"
puts "  3. Can compare behavior of both approaches with same traffic"
puts "  4. Enables gradual rollout with instant rollback capability"
puts "  5. Perfect for A/B testing circuit breaker strategies"

# Final metrics comparison
if resource && resource.circuit_breaker.respond_to?(:metrics)
  puts "\nFinal Metrics Comparison:"
  metrics = resource.circuit_breaker.metrics
  puts "  Currently active: #{metrics[:active]}"
  puts "  Legacy: #{metrics[:legacy].inspect}"
  puts "  Adaptive: #{metrics[:adaptive].inspect}"
end

